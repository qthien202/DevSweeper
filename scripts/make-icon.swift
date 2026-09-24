// Vẽ icon app → Resources/AppIcon.icns
// Chạy: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Nền squircle theo lưới icon macOS (824pt, bo 185)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x1F6FEB))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [rgb(0x2EC4A0), rgb(0x1A5FD6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
// ánh sáng nhẹ phía trên
let gloss = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Nhánh git (toạ độ gốc ở dưới-trái)
let white = rgb(0xFFFFFF)
let mainX: CGFloat = 400
let topNode = CGPoint(x: mainX, y: 720)
let bottomNode = CGPoint(x: mainX, y: 300)
let branchNode = CGPoint(x: 630, y: 560)

ctx.setStrokeColor(white)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.move(to: bottomNode); ctx.addLine(to: topNode)
ctx.strokePath()
ctx.move(to: CGPoint(x: mainX, y: 360))
ctx.addCurve(to: branchNode, control1: CGPoint(x: mainX, y: 500), control2: CGPoint(x: branchNode.x, y: 420))
ctx.strokePath()

for p in [topNode, bottomNode, branchNode] {
    ctx.setFillColor(white)
    ctx.fillEllipse(in: CGRect(x: p.x - 70, y: p.y - 70, width: 140, height: 140))
    ctx.setFillColor(rgb(0x22A3B8))
    ctx.fillEllipse(in: CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64))
}

// Tia lấp lánh = "đã dọn sạch"
func sparkle(center c: CGPoint, radius r: CGFloat, color: CGColor) {
    let inner = r * 0.22
    let path = CGMutablePath()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let len = i % 2 == 0 ? r : inner
        let pt = CGPoint(x: c.x + cos(angle) * len, y: c.y + sin(angle) * len)
        i == 0 ? path.move(to: pt) : path.addLine(to: pt)
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}
sparkle(center: CGPoint(x: 700, y: 790), radius: 120, color: rgb(0xFFE38A))
sparkle(center: CGPoint(x: 780, y: 330), radius: 70, color: rgb(0xFFFFFF, 0.9))

// Xuất iconset
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let full = ctx.makeImage()!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(full, in: CGRect(x: 0, y: 0, width: px, height: px))
        let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! NSBitmapImageRep(cgImage: full).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✅ Resources/AppIcon.icns" : "❌ iconutil failed")
