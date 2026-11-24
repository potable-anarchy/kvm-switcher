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
let vcpInput: UInt8 = 0x60
let vcpKVM: UInt8 = 0xE7
let vcpPBP: UInt8 = 0xE9
let kvmToggle: UInt16 = 0xFF00
let hubVendor = 0x0BDA, hubProduct = 0x5409 // monitor's USB hub (Realtek)

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
        for _ in 0..<3 {
            usleep(10_000)
            if write(service, 0x37, 0x51, &p, UInt32(p.count)) == kIOReturnSuccess { return true }
        }
        return false
    }

    func read(_ vcp: UInt8) -> UInt16? {
        guard let write = AV.write, let read = AV.read else { return nil }
        for _ in 0..<4 {
            var p: [UInt8] = [0x82, 0x01, vcp, 0]
            p[3] = DDC.checksum(0x6E ^ 0x51, p[0..<3])
            guard write(service, 0x37, 0x51, &p, UInt32(p.count)) == kIOReturnSuccess else { usleep(20_000); continue }
            usleep(40_000)
            var r = [UInt8](repeating: 0, count: 11)
            guard read(service, 0x37, 0x51, &r, UInt32(r.count)) == kIOReturnSuccess else { continue }
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
                    msg = d.write(vcpInput, linuxInput) ? "Switched input to Linux" : "Input write failed"
                }
            } else {
                msg = "Monitor not reachable over DDC"
            }
            DispatchQueue.main.async { done(msg) }
        }
    }
}

// MARK: - Hotkey (Carbon: works without Accessibility permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    static var onPress: (() -> Void)?

    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4B56_4D53), id: 1) // 'KVMS'
        let mods = UInt32(controlKey | optionKey | cmdKey)
        return RegisterEventHotKey(UInt32(kVK_ANSI_K), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let monitor = Monitor()
    let hotKey = HotKey()
    var item: NSStatusItem!
    let statusLine = NSMenuItem(title: "Checking monitor…", action: nil, keyEquivalent: "")
    let lastAction = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "KVM Switch")
        img?.isTemplate = true
        item.button?.image = img

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        lastAction.isEnabled = false
        lastAction.isHidden = true
        let sw = NSMenuItem(title: "Switch to Other Computer", action: #selector(switchNow), keyEquivalent: "k")
        sw.keyEquivalentModifierMask = [.control, .option, .command]
        for i in [sw, loginItem] { i.target = self }
        menu.addItem(statusLine)
        menu.addItem(lastAction)
        menu.addItem(.separator())
        menu.addItem(sw)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit KVM Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        HotKey.onPress = { [weak self] in self?.switchNow() }
        if !hotKey.register() {
            show("⌃⌥⌘K is taken by another app")
        }
    }

    func menuWillOpen(_: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusLine.title = "Checking monitor…"
        monitor.state { [weak self] s in
            guard let self else { return }
            guard let s else { self.statusLine.title = "Monitor not reachable over DDC"; return }
            let input = s.input == linuxInput ? "Linux" : (s.input == 0x1B ? "Mac" : String(format: "0x%02X", s.input))
            self.statusLine.title = "PBP \(s.pbp ? "on" : "off") · input \(input) · keyboard \(s.usbHere ? "here" : "on other computer")"
        }
    }

    @objc func switchNow() {
        flash()
        monitor.toggle { [weak self] msg in self?.show(msg) }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
