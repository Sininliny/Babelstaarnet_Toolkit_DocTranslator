import CoreGraphics
import Foundation

/// Page images, made small enough for a model to look at.
///
/// Two different sizes are right for the two readers, and neither is the
/// other's. The recognizer wants every stroke of every hanzi and gets the
/// page at 300 dpi. A vision-language model works from a fixed internal
/// representation whatever it is handed, so anything past about 1500 pixels
/// on the long side costs encode time, memory, and context window without
/// being looked at any more closely.
public enum ImageScaling {
    public static func scaled(_ image: CGImage, longSide: Int) -> CGImage? {
        let current = max(image.width, image.height)
        guard current > longSide else { return image }
        let factor = Double(longSide) / Double(current)
        let width = Int((Double(image.width) * factor).rounded())
        let height = Int((Double(image.height) * factor).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // High, because the whole point of the downscale is that the text
        // survives it: a nearest-neighbour shrink of dense type is where the
        // strokes of 田 close up.
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return context.makeImage()
    }
}
