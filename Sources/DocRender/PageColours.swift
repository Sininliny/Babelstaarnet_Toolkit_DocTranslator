import CoreGraphics
import Foundation

/// The two colours a block of text is made of.
///
/// Replacing text in place needs both: something to paint over the Chinese
/// with, and something to write the English in. Guessing white-on-black is
/// wrong on half the documents anyone actually has — a red seal, a grey
/// table cell, a coloured letterhead band, a scan with a cream cast — so
/// both are measured from the block itself.
///
/// The measurement is a histogram rather than an average. Averaging a page of
/// black text on white paper gives grey, which is the one colour that is
/// neither the background nor the ink.
public struct PageColours {
    public let background: CGColor
    public let ink: CGColor

    static let fallback = PageColours(
        background: CGColor(gray: 1, alpha: 1),
        ink: CGColor(gray: 0, alpha: 1)
    )

    /// Sampled from a shrunk copy of the block: the colours of a paragraph
    /// survive a downscale, and a full-resolution histogram of a 300 dpi
    /// block is a million pixels to answer a question about two.
    static let sampleSide = 96
    /// Five bits a channel. Fine enough to keep a pale blue apart from a
    /// pale grey, coarse enough that antialiasing does not scatter the
    /// background across a hundred buckets.
    static let quantization = 3

    public static func sample(_ image: CGImage, box: CGRect) -> PageColours {
        let clamped = box.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard clamped.width >= 2, clamped.height >= 2,
              let cropped = image.cropping(to: clamped) else {
            return .fallback
        }

        let scale = min(
            1,
            Double(sampleSide) / Double(max(cropped.width, cropped.height))
        )
        let width = max(1, Int(Double(cropped.width) * scale))
        let height = max(1, Int(Double(cropped.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Nearest neighbour, deliberately. Every other downscale in this
            // project asks for the best interpolation available; this one
            // must not have it. Smoothing a 300 dpi line of type down to a
            // thumbnail averages each stroke with the paper around it, and
            // what comes out the other side is a block with no black pixels
            // in it at all — after which the ink samples as grey however
            // carefully the histogram is read.
            context.interpolationQuality = .none
            context.draw(
                cropped,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard drawn else { return .fallback }

        var counts: [Int: Int] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index])
            let g = Int(pixels[index + 1])
            let b = Int(pixels[index + 2])
            let key = (r >> quantization) << 10
                | (g >> quantization) << 5
                | (b >> quantization)
            counts[key, default: 0] += 1
            let running = sums[key] ?? (0, 0, 0)
            sums[key] = (running.r + r, running.g + g, running.b + b)
        }

        guard let backgroundKey = counts.max(by: { $0.value < $1.value })?.key,
              let backgroundCount = counts[backgroundKey],
              let backgroundSum = sums[backgroundKey] else {
            return .fallback
        }
        let background = colour(backgroundSum, count: backgroundCount)

        // The ink is the *far end* of the block, not its most popular
        // non-background shade. Antialiasing fills a page of black text on
        // white paper with far more mid-grey pixels than black ones, so
        // anything that weights by frequency picks the grey — and the
        // translation comes out looking like a faded photocopy of itself.
        //
        // So: take the pixels furthest from the background, and average the
        // darkest sixth of them. Enough pixels to be the typeface rather than
        // a speck of dust, few enough to be its core rather than its edges.
        let ranked = counts.compactMap { key, count -> (Double, Int, (r: Int, g: Int, b: Int))? in
            guard key != backgroundKey, let sum = sums[key] else { return nil }
            return (distance(colour(sum, count: count), background), count, sum)
        }
        .sorted { $0.0 > $1.0 }

        // A quarter of the *ink* pixels, not a quarter of the block. Most of
        // a block of text is paper, and a fraction taken over the whole block
        // sweeps up the entire antialiased halo — whose average is exactly
        // the mid-grey this is trying to avoid.
        let candidates = ranked.filter { $0.0 > 0.12 }
        let pool = candidates.reduce(0) { $0 + $1.1 }
        let wanted = max(1, pool / 4)
        var taken = 0
        var inkSum = (r: 0, g: 0, b: 0)
        var inkCount = 0
        for (_, count, sum) in candidates {
            inkSum = (inkSum.r + sum.r, inkSum.g + sum.g, inkSum.b + sum.b)
            inkCount += count
            taken += count
            if taken >= wanted { break }
        }
        let best: (score: Double, colour: CGColor)? = inkCount > 0
            ? (1, colour(inkSum, count: inkCount))
            : nil

        // A block with no second colour is a block with no text in it. Black
        // or white, whichever the background is not.
        let fallbackInk = luminance(background) > 0.5
            ? CGColor(gray: 0, alpha: 1)
            : CGColor(gray: 1, alpha: 1)
        return PageColours(
            background: background,
            ink: best?.colour ?? fallbackInk
        )
    }

    private static func colour(
        _ sum: (r: Int, g: Int, b: Int),
        count: Int
    ) -> CGColor {
        CGColor(
            red: Double(sum.r) / Double(count) / 255,
            green: Double(sum.g) / Double(count) / 255,
            blue: Double(sum.b) / Double(count) / 255,
            alpha: 1
        )
    }

    private static func distance(_ lhs: CGColor, _ rhs: CGColor) -> Double {
        let a = lhs.components ?? [0, 0, 0]
        let b = rhs.components ?? [0, 0, 0]
        guard a.count >= 3, b.count >= 3 else { return 0 }
        let dr = Double(a[0] - b[0])
        let dg = Double(a[1] - b[1])
        let db = Double(a[2] - b[2])
        return ((dr * dr + dg * dg + db * db) / 3).squareRoot()
    }

    public static func luminance(_ colour: CGColor) -> Double {
        let components = colour.components ?? [0, 0, 0]
        guard components.count >= 3 else { return 0 }
        return 0.2126 * Double(components[0])
            + 0.7152 * Double(components[1])
            + 0.0722 * Double(components[2])
    }
}
