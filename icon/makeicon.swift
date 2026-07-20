import Cocoa

let size: CGFloat = 1024
let outDir = "/tmp/spaceprobe/icon"

func drawIcon(pixelSize: Int, to path: String) {
    let s = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024.0 // unit scale

    // --- squircle (superellipse approx via continuous corners)
    func squircle(_ rect: CGRect, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    }

    // background
    let bgRect = CGRect(x: 24*u, y: 24*u, width: 976*u, height: 976*u)
    ctx.saveGState()
    squircle(bgRect, 224*u).addClip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.42, green: 0.18, blue: 0.86, alpha: 1),
                 CGColor(red: 0.22, green: 0.10, blue: 0.55, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    // subtle top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s*0.55), options: [])
    ctx.restoreGState()

    // inner stroke
    ctx.saveGState()
    squircle(bgRect.insetBy(dx: 3*u, dy: 3*u), 216*u).addClip()
    NSColor.white.withAlphaComponent(0.14).setStroke()
    squircle(bgRect.insetBy(dx: 3*u, dy: 3*u), 216*u).lineWidth = 6*u
    squircle(bgRect.insetBy(dx: 3*u, dy: 3*u), 216*u).stroke()
    ctx.restoreGState()

    // --- three desktop thumbnails
    let thumbW: CGFloat = 250*u, thumbH: CGFloat = 168*u, gap: CGFloat = 36*u
    let totalW = 3*thumbW + 2*gap
    let x0 = (1024*u - totalW)/2
    let yT = 570*u
    for i in 0..<3 {
        let r = CGRect(x: x0 + CGFloat(i)*(thumbW+gap), y: yT, width: thumbW, height: thumbH)
        let selected = (i == 1)
        // shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8*u), blur: 18*u, color: CGColor(gray: 0, alpha: 0.35))
        NSColor.white.withAlphaComponent(selected ? 0.98 : 0.55).setFill()
        squircle(r, 34*u).fill()
        ctx.restoreGState()
        // thumbnail "content" lines
        if !selected {
            NSColor(red: 0.35, green: 0.2, blue: 0.6, alpha: 0.35).setFill()
            for j in 0..<3 {
                let lr = CGRect(x: r.minX + 30*u, y: r.maxY - 44*u - CGFloat(j)*34*u, width: (thumbW-90*u) * (1 - CGFloat(j)*0.2), height: 14*u)
                squircle(lr, 7*u).fill()
            }
        } else {
            // window bars on selected
            NSColor(red: 0.48, green: 0.24, blue: 0.85, alpha: 0.85).setFill()
            for j in 0..<3 {
                let lr = CGRect(x: r.minX + 30*u, y: r.maxY - 44*u - CGFloat(j)*34*u, width: (thumbW-90*u) * (1 - CGFloat(j)*0.2), height: 14*u)
                squircle(lr, 7*u).fill()
            }
        }
    }

    // --- name pill under the middle thumbnail
    let pillW: CGFloat = 330*u, pillH: CGFloat = 96*u
    let pillRect = CGRect(x: (1024*u - pillW)/2, y: yT - 150*u, width: pillW, height: pillH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6*u), blur: 14*u, color: CGColor(gray: 0, alpha: 0.4))
    NSColor(white: 0.12, alpha: 0.92).setFill()
    squircle(pillRect, pillH/2).fill()
    ctx.restoreGState()
    // pill text
    let text = "Aa" as NSString
    let font = NSFont.systemFont(ofSize: 52*u, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let tsize = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: pillRect.midX - tsize.width/2, y: pillRect.midY - tsize.height/2), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let set = "/tmp/spaceprobe/icon/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs { drawIcon(pixelSize: px, to: "\(set)/\(name)") }
drawIcon(pixelSize: 1024, to: "\(outDir)/preview.png")
print("iconset done")
