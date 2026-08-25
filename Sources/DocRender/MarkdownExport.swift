import DocCore
import Foundation

/// The document as Markdown.
public enum MarkdownExport {
    public static func render(
        _ document: TranslatedDocument,
        style: ExportStyle
    ) -> String {
        var output = "# \(document.source.displayName)\n\n"
        for line in document.provenance() {
            output += "> \(line)\n"
        }
        output += "\n"

        for page in document.pages {
            if document.pages.count > 1 {
                output += "## Page \(page.index + 1)\n\n"
            }
            for block in page.blocks {
                output += rendered(block, style: style)
            }
        }
        return output
    }

    private static func rendered(
        _ block: TranslatedBlock,
        style: ExportStyle
    ) -> String {
        let english = block.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !english.isEmpty else { return "" }

        var output = ""
        if style.includesSource {
            // The source as a quote, so a reader scanning the English is not
            // reading through a script they cannot read.
            output += "> \(block.source.text)\n\n"
        }

        switch block.source.kind {
        case .heading:
            output += "### \(english)\n\n"
        case .listItem:
            output += "- \(english)\n\n"
        case .pageFurniture:
            output += "*\(english)*\n\n"
        default:
            output += "\(english)\n\n"
        }

        if block.confidence.band != .high {
            output += "*\(marker(block))*\n\n"
        }
        if style.includesWorking {
            output += working(block)
        }
        return output
    }

    private static func marker(_ block: TranslatedBlock) -> String {
        let reasons = block.confidence.reasons.joined(separator: "; ")
        return "⚠︎ \(block.confidence.band.label) — \(reasons)"
    }

    private static func working(_ block: TranslatedBlock) -> String {
        var output = "<details><summary>How this block was read</summary>\n\n"
        for (reader, text) in block.source.candidates.sorted(by: {
            $0.key.rawValue < $1.key.rawValue
        }) {
            output += "- **\(reader.displayName):** \(text)\n"
        }
        output += "- **Settled:** \(block.source.settlement.summary)\n"
        if block.wasRevised {
            output += "- **First draft:** \(block.firstDraft)\n"
        }
        for finding in block.findings {
            output += "- **Check:** \(finding.message)\n"
        }
        output += "\n</details>\n\n"
        return output
    }
}
