import AppKit
import CoreGraphics
import CoreText
import Foundation

// The icon says what the app does and nothing else: one page, one character
// of the language you cannot read, and one letter of the language you can,
// with the line between them where the work happens.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: generate-app-icon.swift <output.iconset>")
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func draw(size: CGFloat) -> CGImage? {
    let pixels = Int(size)
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let plate = rect.insetBy(dx: inset, dy: inset)
    let corner = size * 0.22

    // Paper, warmed slightly at the top so the plate has a light source.
    let background = CGPath(
        roundedRect: plate,
        cornerWidth: corner,
        cornerHeight: corner,
        transform: nil
    )
    context.saveGState()
    context.addPath(background)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.99, green: 0.97, blue: 0.93, alpha: 1),
            CGColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: plate.maxY),
            end: CGPoint(x: 0, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    // The rule down the middle: the source on one side, the reader's language
    // on the other.
    let ruleWidth = max(1, size * 0.008)
    context.setFillColor(CGColor(red: 0.42, green: 0.33, blue: 0.24, alpha: 0.5))
    context.fill(
        CGRect(
            x: rect.midX - ruleWidth / 2,
            y: plate.minY + plate.height * 0.22,
            width: ruleWidth,
            height: plate.height * 0.56
        )
    )

    func glyph(
        _ text: String,
        font name: String,
        centeredAt point: CGPoint,
        size fontSize: CGFloat,
        color: CGColor
    ) {
        let font = CTFontCreateWithName(name as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: point.x - bounds.width / 2 - bounds.minX,
            y: point.y - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }

    let ink = CGColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
    let faded = CGColor(red: 0.36, green: 0.30, blue: 0.24, alpha: 0.85)

    glyph(
        "文",
        font: "PingFangSC-Semibold",
        centeredAt: CGPoint(x: rect.midX - plate.width * 0.21, y: rect.midY),
        size: size * 0.34,
        color: ink
    )
    glyph(
        "A",
        font: "HelveticaNeue-Medium",
        centeredAt: CGPoint(x: rect.midX + plate.width * 0.21, y: rect.midY),
        size: size * 0.34,
        color: faded
    )

    return context.makeImage()
}

// The sizes `iconutil` expects, and no others.
let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1_024)
]

for (name, pixels) in sizes {
    guard let image = draw(size: pixels) else {
        print("could not draw \(name)")
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        print("could not write \(name)")
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

print("Wrote \(sizes.count) icon sizes to \(outputDirectory.path)")
