import DocCore
import Foundation

/// The words, and nothing else.
///
/// Deliberately free of everything the other exports add: no provenance
/// header, no confidence marks, no headings made of hashes. This output
/// exists to be pasted into an email, a form, or a search box, and anything
/// the app adds to it is something the reader has to delete.
///
/// What it does keep is the shape of the reading: paragraphs stay separate,
/// list items keep their bullets, and pages are divided by a blank line
/// rather than by a rule, because a rule is markup too.
public enum PlainTextExport {
    public static func render(
        _ document: TranslatedDocument,
        includingPageFurniture: Bool = false
    ) -> String {
        var pages: [String] = []
        for page in document.pages {
            var paragraphs: [String] = []
            for block in page.blocks {
                if !includingPageFurniture,
                   block.source.kind == .pageFurniture {
                    continue
                }
                let text = block.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !text.isEmpty else { continue }
                paragraphs.append(
                    block.source.kind == .listItem && !text.hasPrefix("•")
                        ? "• " + text
                        : text
                )
            }
            if !paragraphs.isEmpty {
                pages.append(paragraphs.joined(separator: "\n\n"))
            }
        }
        return pages.joined(separator: "\n\n") + "\n"
    }
}
