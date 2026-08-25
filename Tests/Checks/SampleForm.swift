import CoreGraphics
import DocAgents
import DocCore
import DocIngest
import DocOCR
import DocRender
import Foundation
import ImageIO
import LanguageChinese
import PDFKit
import UniformTypeIdentifiers

/// The form from `Fixtures.table`, translated and written out beside the
/// original, so the hard case for the layout-preserving export can be looked
/// at rather than only asserted about.
///
/// Everything except the translation is the real thing: Vision reads the
/// drawn page, the assembler decides what a block is, the colours are sampled
/// from the pixels and the English is fitted and drawn by the exporter. The
/// English itself comes from a table of terms in this file, so the same
/// picture comes out on a Mac with no model on it.
enum SampleForm {
    static let terms: [String: String] = [
        "项目": "Item",
        "结果": "Result",
        "参考值": "Reference value",
        "单位": "Unit",
        "总硬度": "Total hardness",
        "溶解性总固体": "Total dissolved solids",
        "耗氧量": "Oxygen consumption",
        "浑浊度": "Turbidity",
        "色度": "Colour",
        "挥发性酚类": "Volatile phenols",
        "阴离子合成洗涤剂": "Anionic synthetic detergents",
        "氨氮": "Ammonia nitrogen",
        "硝酸盐氮": "Nitrate nitrogen",
        "亚硝酸盐氮": "Nitrite nitrogen",
        "氯化物": "Chloride",
        "硫酸盐": "Sulfate",
        "铁": "Iron",
        "锰": "Manganese",
        "铜": "Copper",
        "挥发性有机化合物总量": "Total volatile organic compounds",
        "菌落总数": "Total bacterial count",
        "游离氯": "Free chlorine",
        "碱度": "Alkalinity",
        "钠": "Sodium",
        "酸碱度": "pH value",
        "电导率": "Electrical conductivity",
        "钙": "Calcium",
        "镁": "Magnesium",
        "注释": "Note",
        "的": " for ",
        "度": "degrees"
    ]

    /// Longest first, so 酸碱度 is not translated as 酸 followed by 碱度.
    static let ordered = terms.keys.sorted { $0.count > $1.count }

    static func english(for source: String) -> String {
        var text = source
        for chinese in ordered {
            text = text.replacingOccurrences(
                of: chinese,
                with: terms[chinese] ?? chinese
            )
        }
        return text
    }

    static func write(to directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let image = Fixtures.table() else {
            throw Failure.couldNotDraw
        }

        let original = directory.appendingPathComponent("form-original.png")
        try write(image, to: original)

        let provider = try DocumentLoader.open(original)
        let document = try await TranslationPipeline(
            languages: SimplifiedChinese.toEnglish,
            engines: Engines(
                readers: [VisionTranscriber()],
                textAgent: nil,
                machineTranslator: ScriptedTranslator { english(for: $0) },
                preference: .fastest
            )
        ).run(provider)

        let pdf = try LayoutPreservingPDF.render(document, pages: provider)
        let written = directory.appendingPathComponent("form-translated.pdf")
        try pdf.write(to: written, options: .atomic)
        if let raster = raster(pdf) {
            try write(
                raster,
                to: directory.appendingPathComponent("form-translated.png")
            )
        }

        print("Wrote form-original.png, form-translated.pdf and "
            + "form-translated.png to \(directory.path)")
    }

    /// The PDF as pixels, because a rendering fault is something you look at.
    private static func raster(_ pdf: Data) -> CGImage? {
        guard let document = PDFDocument(data: pdf),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: bounds.size))
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw Failure.couldNotDraw }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.couldNotDraw
        }
    }

    enum Failure: Error {
        case couldNotDraw
    }
}
