import CoreGraphics
import DocAgents
import DocCore
import DocIngest
import DocOCR
import DocRender
import Foundation
import ImageIO
import LanguageChinese
import UniformTypeIdentifiers

/// Writes a page and its translated copy, so the layout-preserving export can
/// be looked at rather than only asserted about.
///
/// The reading, the block boundaries, the colour sampling, the fitting and the
/// drawing are all the real thing. The *translation* comes from a table in
/// this file rather than from a model, so that this produces the same output
/// on a Mac with no model available — which is the machine most likely to be
/// running it to see what the mode does.
enum Sample {
    /// Lines short enough to fit the page's measure, with blank lines
    /// between the blocks — which is how a real page tells one paragraph from
    /// the next, and the only signal the assembler has.
    static let page = [
        "北京市朝阳区人民法院",
        "",
        "关于门禁系统升级的通知",
        "",
        "各部门同事：",
        "",
        "为加强办公区域安全管理，",
        "本院定于2024年3月15日起",
        "对门禁系统进行升级。",
        "",
        "升级期间请携带工作证，",
        "逾期未领取新卡的罚款为500元。",
        "",
        "行政办公室 010-12345678"
    ]

    static let english: [String: String] = [
        "北京市朝阳区人民法院":
            "Chaoyang District People's Court, Beijing",
        "关于门禁系统升级的通知":
            "Notice on the access control system upgrade",
        "各部门同事：": "To colleagues in all departments:",
        "为加强办公区域安全管理，本院定于2024年3月15日起对门禁系统进行升级。":
            "To strengthen security management of the office areas, this "
            + "court will upgrade the access control system from 15 March "
            + "2024.",
        "升级期间请携带工作证，逾期未领取新卡的罚款为500元。":
            "Please carry your staff card during the upgrade. A fine of 500 "
            + "yuan applies if a new card is not collected in time.",
        "行政办公室 010-12345678":
            "Administrative Office 010-12345678"
    ]

    static func write(to directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        guard let image = Fixtures.page(
            lines: page,
            footer: "第 1 页",
            fontSize: 40,
            startY: 190
        ) else {
            throw SampleFailure.couldNotDraw
        }

        let original = directory.appendingPathComponent("sample-original.png")
        guard let destination = CGImageDestinationCreateWithURL(
            original as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw SampleFailure.couldNotDraw }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SampleFailure.couldNotDraw
        }

        let provider = try DocumentLoader.open(original)
        let document = try await TranslationPipeline(
            languages: SimplifiedChinese.toEnglish,
            engines: Engines(
                readers: [VisionTranscriber()],
                textAgent: nil,
                machineTranslator: ScriptedTranslator { source in
                    // Matched loosely: the recognizer's reading of a line
                    // will not always be character-for-character what was
                    // printed, and this is a demonstration of the layout, not
                    // of the lookup.
                    english[source] ?? bestMatch(for: source) ?? source
                },
                preference: .fastest
            )
        ).run(provider)

        let pdf = try LayoutPreservingPDF.render(document, pages: provider)
        try pdf.write(
            to: directory.appendingPathComponent("sample-translated.pdf"),
            options: .atomic
        )
        try PlainTextExport.render(document).write(
            to: directory.appendingPathComponent("sample-text.txt"),
            atomically: true,
            encoding: .utf8
        )

        print("Wrote sample-original.png, sample-translated.pdf and "
            + "sample-text.txt to \(directory.path)")
    }

    private static func bestMatch(for source: String) -> String? {
        var best: (score: Double, text: String)?
        for (chinese, translation) in english {
            let score = TextSimilarity.score(chinese, source)
            if score > 0.75, score > (best?.score ?? 0) {
                best = (score, translation)
            }
        }
        return best?.text
    }

    enum SampleFailure: Error {
        case couldNotDraw
    }
}
