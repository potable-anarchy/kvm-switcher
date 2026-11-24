// KVM Switch — menu-bar app for Apple Silicon Macs.
//
// Ctrl+Option+Cmd+K hands the Alienware AW3926QW's keyboard/mouse to the other
// computer. PBP on → toggle the USB/KVM only (VCP 0xE7 = 0xFF00).
// PBP off → switch the monitor input to the Linux machine (VCP 0x60).
//
// DDC/CI goes through IOKit's IOAVService I2C calls (the same private API used by
// m1ddc and MonitorControl), resolved at runtime with dlsym.

import AppKit
import Carbon.HIToolbox
import IOKit
import ServiceManagement

// MARK: - Settings (override with `defaults write io.github.potable-anarchy.kvm-switch <key> -int <n>`)

let defaults = UserDefaults.standard
var linuxInput: UInt16 { UInt16(defaults.object(forKey: "linuxInput") as? Int ?? 0x0F) } // DisplayPort-1
var macInput: UInt16 { UInt16(defaults.object(forKey: "macInput") as? Int ?? 0x1B) }     // USB-C
let pbpOnValue: UInt16 = 0x24
let vcpInput: UInt8 = 0x60
let vcpKVM: UInt8 = 0xE7
let vcpPBP: UInt8 = 0xE9
let kvmToggle: UInt16 = 0xFF00
let hubVendor = 0x0BDA, hubProduct = 0x5409 // monitor's USB hub (Realtek)

let readWriteCycles = Int(ProcessInfo.processInfo.environment["KVM_CYCLES"] ?? "") ?? 2
let debug = ProcessInfo.processInfo.environment["KVM_DEBUG"] != nil
func dbg(_ s: @autoclosure () -> String) { if debug { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) } }

// MARK: - IOAVService (private IOKit API)

typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

struct AV {
    static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    static let create = sym("IOAVServiceCreateWithService", CreateFn.self)
    static let read = sym("IOAVServiceReadI2C", I2CFn.self)
    static let write = sym("IOAVServiceWriteI2C", I2CFn.self)
}

/// One external display reachable over DDC/CI.
final class DDC {
    let service: CFTypeRef
    init(_ service: CFTypeRef) { self.service = service }

    /// Every external display's AV service, in IORegistry order.
    static func externalDisplays() -> [DDC] {
        guard let create = AV.create else { return [] }
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [DDC] = []
        while true {
            let entry = IOIteratorNext(iter)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            dbg("DCPAVServiceProxy entry \(entry): Location=\(loc ?? "nil")")
            guard loc == "External", let av = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            out.append(DDC(av))
        }
        return out
    }

    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 { bytes.reduce(seed, ^) }

    /// Write once (no retry after success: 0xE7 is a toggle, so a double write would undo it).
    func write(_ vcp: UInt8, _ value: UInt16) -> Bool {
        guard let write = AV.write else { return false }
        var p: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        p[5] = DDC.checksum(0x6E ^ 0x51, p[0..<5])
        let cycles = Int(ProcessInfo.processInfo.environment["KVM_WCYCLES"] ?? "") ?? 2
        var ok = false
        for _ in 0..<cycles {
            usleep(10_000)
            ok = write(service, 0x37, 0x51, &p, UInt32(p.count)) == kIOReturnSuccess
        }
        return ok
    }

    func read(_ vcp: UInt8) -> UInt16? {
        guard let write = AV.write, let read = AV.read else { return nil }
        for _ in 0..<4 {
            var p: [UInt8] = [0x82, 0x01, vcp, 0]
            p[3] = DDC.checksum(0x6E ^ 0x51, p[0..<3])
            // MonitorControl sends the request twice; some monitors drop the first one.
            var wr = kIOReturnSuccess
            for c in 0..<readWriteCycles {
                if c > 0 { usleep(10_000) }
                wr = write(service, 0x37, 0x51, &p, UInt32(p.count))
            }
            dbg("read 0x\(String(vcp, radix: 16)): write request -> \(String(format: "0x%08x", wr))")
            guard wr == kIOReturnSuccess else { usleep(20_000); continue }
            usleep(UInt32(ProcessInfo.processInfo.environment["KVM_DELAY_MS"].flatMap(Int.init) ?? 40) * 1000)
            var r = [UInt8](repeating: 0, count: 11)
            let rr = read(service, 0x37, 0x51, &r, UInt32(r.count))
            dbg("  read reply -> \(String(format: "0x%08x", rr)) bytes \(r.map { String(format: "%02x", $0) }.joined(separator: " "))")
            guard rr == kIOReturnSuccess else { continue }
            // r: [src, len, 0x02 opcode, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]
            guard r[2] == 0x02, r[3] == 0x00, r[4] == vcp, DDC.checksum(0x50, r[0..<10]) == r[10] else { continue }
            return UInt16(r[8]) << 8 | UInt16(r[9])
        }
        return nil
    }
}

// MARK: - Monitor logic

struct MonitorState { var pbp: Bool; var input: UInt16; var usbHere: Bool }

final class Monitor {
    private var cached: DDC?
    private let queue = DispatchQueue(label: "kvm-switch.ddc")
    private var busy = false

    /// First external display that answers an input-source read.
    private func display() -> DDC? {
        if let c = cached, c.read(vcpInput) != nil { return c }
        cached = DDC.externalDisplays().first { $0.read(vcpInput) != nil }
        return cached
    }

    static func usbHere() -> Bool {
        guard let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        m["idVendor"] = hubVendor
        m["idProduct"] = hubProduct
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m as CFDictionary, &iter) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iter) }
        let s = IOIteratorNext(iter)
        if s != 0 { IOObjectRelease(s); return true }
        return false
    }

    func state(_ done: @escaping (MonitorState?) -> Void) {
        queue.async {
            guard let d = self.display(), let pbp = d.read(vcpPBP), let input = d.read(vcpInput) else {
                return DispatchQueue.main.async { done(nil) }
            }
            let s = MonitorState(pbp: pbp & 0xFF != 0, input: input & 0xFF, usbHere: Monitor.usbHere())
            DispatchQueue.main.async { done(s) }
        }
    }

    /// Run `body` on the DDC queue, one command at a time; report its message on the main queue.
    private func run(_ done: @escaping (String) -> Void, _ body: @escaping (DDC) -> String) {
        queue.async {
            if self.busy { return }
            self.busy = true
            defer { self.busy = false }
            let msg = self.display().map(body) ?? "Monitor not reachable over DDC"
            DispatchQueue.main.async { done(msg) }
        }
    }

    /// PBP on <-> off. Turning it off also puts this Mac full-screen (otherwise the main input,
    /// Linux, would take the screen and the keyboard with it).
    func togglePBP(_ done: @escaping (String) -> Void) {
        run(done) { d in
            guard let pbp = d.read(vcpPBP) else { return "Couldn't read PBP state" }
            if pbp & 0xFF == 0 { return d.write(vcpPBP, pbpOnValue) ? "PBP on" : "PBP write failed" }
            guard d.write(vcpPBP, 0x00) else { return "PBP write failed" }
            // The display re-syncs after PBP changes; retry (re-finding the display) for a few seconds.
            for _ in 0..<6 {
                usleep(500_000)
                if let dd = self.display(), dd.write(vcpInput, macInput) { return "PBP off · screen on this Mac" }
            }
            return "PBP off (couldn't switch input to this Mac)"
        }
    }

    /// Full-screen input switch DP <-> USB-C. Refused while PBP is on.
    func switchInput(_ done: @escaping (String) -> Void) {
        run(done) { d in
            guard let pbp = d.read(vcpPBP) else { return "Couldn't read PBP state" }
            if pbp & 0xFF != 0 { return "Input switch is disabled while PBP is on" }
            let cur = (d.read(vcpInput) ?? 0) & 0xFF
            let target = cur == linuxInput ? macInput : linuxInput
            return d.write(vcpInput, target) ? "Input → \(target == linuxInput ? "Linux" : "Mac")" : "Input write failed"
        }
    }

    /// Hand keyboard/mouse (and the screen if PBP is off) to the other machine.
    func toggle(_ done: @escaping (String) -> Void) {
        queue.async {
            if self.busy { return }
            self.busy = true
            defer { self.busy = false }
            let msg: String
            if let d = self.display(), let pbp = d.read(vcpPBP) {
                if pbp & 0xFF != 0 {
                    msg = d.write(vcpKVM, kvmToggle) ? "PBP: keyboard/mouse toggled" : "KVM write failed"
                } else {
                    let cur = (d.read(vcpInput) ?? 0) & 0xFF
                    let target = cur == linuxInput ? macInput : linuxInput
                    msg = d.write(vcpInput, target) ? "Switched input to \(target == linuxInput ? "Linux" : "Mac")" : "Input write failed"
                }
            } else {
                msg = "Monitor not reachable over DDC"
            }
            DispatchQueue.main.async { done(msg) }
        }
    }
}

// MARK: - Hotkeys (Carbon: works without Accessibility permission)

final class HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    /// Register Ctrl+Option+Cmd+<key>. Returns false if another app already owns it.
    func register(id: UInt32, key: Int, _ handler: @escaping () -> Void) -> Bool {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKeys.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        HotKeys.handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkid = EventHotKeyID(signature: OSType(0x4B56_4D53), id: id) // 'KVMS'
        let ok = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey), hkid,
                                     GetApplicationEventTarget(), 0, &ref) == noErr
        refs.append(ref)
        return ok
    }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let monitor = Monitor()
    let hotKeys = HotKeys()
    var item: NSStatusItem!
    let statusLine = NSMenuItem(title: "Checking monitor…", action: nil, keyEquivalent: "")
    let lastAction = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let pbpItem = NSMenuItem(title: "Toggle PBP", action: #selector(togglePBP), keyEquivalent: "p")
    let inputItem = NSMenuItem(title: "Switch Input (DP ↔ USB-C)", action: #selector(switchInput), keyEquivalent: "")

    func applicationDidFinishLaunching(_: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "KVM Switch")
        img?.isTemplate = true
        item.button?.image = img

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false   // we enable/disable items from the monitor's PBP state
        statusLine.isEnabled = false
        lastAction.isEnabled = false
        lastAction.isHidden = true
        let sw = NSMenuItem(title: "Switch to Other Computer", action: #selector(switchNow), keyEquivalent: "k")
        sw.keyEquivalentModifierMask = [.control, .option, .command]
        pbpItem.keyEquivalentModifierMask = [.control, .option, .command]
        for i in [sw, pbpItem, inputItem, loginItem] { i.target = self }
        menu.addItem(statusLine)
        menu.addItem(lastAction)
        menu.addItem(.separator())
        menu.addItem(sw)
        menu.addItem(pbpItem)
        menu.addItem(inputItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit KVM Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        if !hotKeys.register(id: 1, key: kVK_ANSI_K, { [weak self] in self?.switchNow() }) {
            show("⌃⌥⌘K is taken by another app")
        }
        if !hotKeys.register(id: 2, key: kVK_ANSI_P, { [weak self] in self?.togglePBP() }) {
            show("⌃⌥⌘P is taken by another app")
        }
    }

    func menuWillOpen(_: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusLine.title = "Checking monitor…"
        monitor.state { [weak self] s in
            guard let self else { return }
            guard let s else { self.statusLine.title = "Monitor not reachable over DDC"; return }
            self.pbpItem.title = s.pbp ? "Turn PBP Off" : "Turn PBP On"
            self.inputItem.isEnabled = !s.pbp
            self.inputItem.title = s.pbp ? "Switch Input (disabled while PBP is on)"
                : (s.input == linuxInput ? "Switch Input to USB-C (Mac)" : "Switch Input to DisplayPort (Linux)")
            let input = s.input == linuxInput ? "Linux" : (s.input == 0x1B ? "Mac" : String(format: "0x%02X", s.input))
            self.statusLine.title = "PBP \(s.pbp ? "on" : "off") · input \(input) · keyboard \(s.usbHere ? "here" : "on other computer")"
        }
    }

    @objc func switchNow() {
        flash()
        monitor.toggle { [weak self] msg in self?.show(msg) }
    }

    @objc func togglePBP() {
        flash()
        monitor.togglePBP { [weak self] msg in self?.show(msg) }
    }

    @objc func switchInput() {
        flash()
        monitor.switchInput { [weak self] msg in self?.show(msg) }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            show("Login item: \(error.localizedDescription)")
        }
    }

    private func show(_ msg: String) {
        lastAction.title = msg
        lastAction.isHidden = false
    }

    /// Brief visual confirmation in the menu bar.
    private func flash() {
        item.button?.appearsDisabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.item.button?.appearsDisabled = false }
    }
}

// CLI mode: "KVM Switch.app/Contents/MacOS/KVMSwitch --status | --toggle | --pbp | --input"
let args = CommandLine.arguments.dropFirst()
if args.first == "--read" {  // debug: --read 10 e9 e7 ...
    guard let d = DDC.externalDisplays().first else { exit(1) }
    for h in args.dropFirst() {
        let v = d.read(UInt8(h, radix: 16)!)
        print(h, v.map { String(format: "0x%04X", $0) } ?? "null")
        usleep(200_000)
    }
    exit(0)
}
if args.first == "--kvm" {  // blind KVM toggle on every external display, no reads
    let ds = DDC.externalDisplays()
    for d in ds { print("write E7=FF00:", d.write(vcpKVM, kvmToggle) ? "ok" : "failed") }
    exit(ds.isEmpty ? 1 : 0)
}
if let cmd = args.first, ["--status", "--toggle", "--pbp", "--input"].contains(cmd) {
    let m = Monitor()
    if cmd == "--toggle" {
        m.toggle { print($0); exit(0) }
    } else if cmd == "--pbp" {
        m.togglePBP { print($0); exit(0) }
    } else if cmd == "--input" {
        m.switchInput { print($0); exit(0) }
    } else {
        m.state { s in
            guard let s else { print("Monitor not reachable over DDC"); exit(1) }
            print(String(format: "PBP:   %@\nInput: 0x%02X\nUSB:   %@", s.pbp ? "on" : "off", s.input,
                         s.usbHere ? "this machine (Mac)" : "the other machine"))
            exit(0)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
