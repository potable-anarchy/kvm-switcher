// Renders the KVM Switch app icon at every size macOS wants, then packs AppIcon.icns.
//   swift mac/icon/make-icon.swift mac/AppIcon.icns
// Design: an ultrawide monitor split into two panes (PBP) with a two-way arrow across them,
// on a rounded-square background following the macOS icon grid (824/1024 body).
import AppKit

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024 // design units are 1024x1024, origin top-left (context is flipped)
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
    let rgb = CGColorSpaceCreateDeviceRGB()

    // Background squircle with a soft drop shadow.
    let bg = CGPath(roundedRect: r(100, 100, 824, 824), cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bg); ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.48, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let bgGrad = CGGradient(colorsSpace: rgb, colors: [
        CGColor(red: 0.39, green: 0.40, blue: 0.96, alpha: 1),   // top: indigo
        CGColor(red: 0.12, green: 0.16, blue: 0.47, alpha: 1),   // bottom: deep navy
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 100 * s), end: CGPoint(x: 0, y: 924 * s), options: [])
    ctx.restoreGState()

    // Monitor stand.
    ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
    ctx.addPath(CGPath(roundedRect: r(472, 640, 80, 110), cornerWidth: 10 * s, cornerHeight: 10 * s, transform: nil)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: r(352, 738, 320, 44), cornerWidth: 22 * s, cornerHeight: 22 * s, transform: nil)); ctx.fillPath()

    // Monitor bezel (ultrawide).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8 * s), blur: 18 * s, color: CGColor(gray: 0, alpha: 0.3))
    ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
    ctx.addPath(CGPath(roundedRect: r(170, 300, 684, 360), cornerWidth: 40 * s, cornerHeight: 40 * s, transform: nil)); ctx.fillPath()
    ctx.restoreGState()

    // Two PBP panes.
    let left = CGPath(roundedRect: r(198, 328, 308, 304), cornerWidth: 20 * s, cornerHeight: 20 * s, transform: nil)
    let right = CGPath(roundedRect: r(518, 328, 308, 304), cornerWidth: 20 * s, cornerHeight: 20 * s, transform: nil)
    for (pane, top, bottom) in [
        (left, CGColor(red: 0.47, green: 0.64, blue: 1.0, alpha: 1), CGColor(red: 0.29, green: 0.43, blue: 0.93, alpha: 1)),
        (right, CGColor(red: 0.36, green: 0.88, blue: 0.78, alpha: 1), CGColor(red: 0.15, green: 0.66, blue: 0.62, alpha: 1)),
    ] {
        ctx.saveGState(); ctx.addPath(pane); ctx.clip()
        let g = CGGradient(colorsSpace: rgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 328 * s), end: CGPoint(x: 0, y: 632 * s), options: [])
        ctx.restoreGState()
    }

    // Two-way arrow across both panes.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 4 * s), blur: 10 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(40 * s); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 330 * s, y: 480 * s)); ctx.addLine(to: CGPoint(x: 694 * s, y: 480 * s)); ctx.strokePath()
    for (tip, dir) in [(CGFloat(262), CGFloat(1)), (CGFloat(762), CGFloat(-1))] {
        ctx.move(to: CGPoint(x: tip * s, y: 480 * s))
        ctx.addLine(to: CGPoint(x: (tip + dir * 104) * s, y: 404 * s))
        ctx.addLine(to: CGPoint(x: (tip + dir * 104) * s, y: 556 * s))
        ctx.closePath(); ctx.fillPath()
    }
    ctx.restoreGState()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1) // top-left origin
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(px))
    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
