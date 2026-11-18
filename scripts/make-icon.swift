// Vygeneruje ikonu aplikace Resources/AppIcon.icns.
// Použití (z kořene projektu): swift scripts/make-icon.swift
//
// Motiv: zaoblený čtverec v duchu macOS s modrofialovým přechodem, seznam tří
// aplikací se stavovými tečkami a výrazné bílé tlačítko ▶︎.
import AppKit

// Převod hex barvy (např. 0x4F46E5) na CGColor
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

// Vyplní zaoblený obdélník danou barvou
func fillRoundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat, _ fill: CGColor) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(fill)
    context.fillPath()
}

// Vykreslí ikonu do bitmapy o straně size pixelů.
// Kreslí se v souřadnicích 1024×1024 (počátek vlevo dole) a pak se škáluje.
func renderIcon(size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Tělo ikony podle mřížky macOS: 824×824 s okrajem 100 px a vrženým stínem
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, alpha: 0.35))
    context.addPath(bodyPath)
    context.setFillColor(color(0x4338CA))
    context.fillPath()
    context.restoreGState()

    // Diagonální přechod indigo → tyrkysová, ořezaný na tělo ikony
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x4F46E5), color(0x2563EB), color(0x06B6D4)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    // Jemný lesk v horní polovině
    let gloss = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, alpha: 0.18), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
    context.restoreGState()

    // Seznam aplikací: průsvitné řádky se stavovou tečkou a „textem“.
    // Třetí řádek je kratší, aby nekolidoval s tlačítkem ▶︎.
    let rows: [(y: CGFloat, width: CGFloat, dot: UInt32, text: CGFloat)] = [
        (640, 624, 0x22C55E, 300),
        (500, 624, 0x22C55E, 240),
        (360, 290, 0xF59E0B, 130),
    ]
    for row in rows {
        let rect = CGRect(x: 200, y: row.y, width: row.width, height: 96)
        fillRoundedRect(context, rect, radius: 48, color(0xFFFFFF, alpha: 0.2))

        context.setFillColor(color(row.dot))
        context.fillEllipse(in: CGRect(x: 226, y: row.y + 22, width: 52, height: 52))

        fillRoundedRect(context, CGRect(x: 304, y: row.y + 37, width: row.text, height: 22), radius: 11, color(0xFFFFFF, alpha: 0.85))
    }

    // Bílé kruhové tlačítko se stínem
    let center = CGPoint(x: 690, y: 330)
    let radius: CGFloat = 165
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: color(0x1E1B4B, alpha: 0.45))
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.restoreGState()

    // Trojúhelník ▶︎ se zaoblenými rohy (výplň + tah se zaobleným spojem)
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 652, y: 410))
    triangle.addLine(to: CGPoint(x: 652, y: 250))
    triangle.addLine(to: CGPoint(x: 784, y: 330))
    triangle.closeSubpath()
    context.addPath(triangle)
    context.setFillColor(color(0x4F46E5))
    context.setStrokeColor(color(0x4F46E5))
    context.setLineWidth(34)
    context.setLineJoin(.round)
    context.drawPath(using: .fillStroke)

    return bitmap
}

// Velikosti, které vyžaduje iconutil (název souboru → strana v pixelech)
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

// Iconset vytvoříme v dočasné složce a převedeme ho na .icns
let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

for variant in variants {
    let png = renderIcon(size: variant.size).representation(using: .png, properties: [:])!
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

// Náhled v plné velikosti pro kontrolu (necommituje se, viz .gitignore)
let preview = renderIcon(size: 1024).representation(using: .png, properties: [:])!
try preview.write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil selhal s kódem \(iconutil.terminationStatus)")
}
print("Vytvořeno: Resources/AppIcon.icns")
