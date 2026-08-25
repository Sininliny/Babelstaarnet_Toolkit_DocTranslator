import DocCore
import Foundation

/// The document as one self-contained HTML file.
///
/// Self-contained is the requirement, not a convenience. An export with a
/// stylesheet link or a web font in it makes a request the moment it is
/// opened, from a file whose entire reason for existing is that its contents
/// were never sent anywhere. So: no links, no fonts, no scripts, no images —
/// the CSS is inline and the whole file works with the network unplugged.
public enum HTMLExport {
    public static func render(
        _ document: TranslatedDocument,
        style: ExportStyle
    ) -> String {
        var body = """
            <header>
            <h1>\(escape(document.source.displayName))</h1>
            <p class="provenance">
            """
        body += document.provenance()
            .map { escape($0) }
            .joined(separator: "<br>\n")
        body += "\n</p>\n</header>\n"

        for page in document.pages {
            if document.pages.count > 1 {
                body += "<h2 class=\"page\">Page \(page.index + 1)</h2>\n"
            }
            for block in page.blocks {
                body += rendered(
                    block,
                    style: style,
                    sourceLanguage: document.languages.source.identifier
                )
            }
        }

        return """
            <!DOCTYPE html>
            <html lang="\(document.languages.target.identifier)">
            <head>
            <meta charset="utf-8">
            <title>\(escape(document.source.displayName))</title>
            <style>\(stylesheet)</style>
            </head>
            <body class="\(style.rawValue)">
            \(body)
            </body>
            </html>
            """
    }

    private static func rendered(
        _ block: TranslatedBlock,
        style: ExportStyle,
        sourceLanguage: String
    ) -> String {
        let english = block.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !english.isEmpty else { return "" }

        var output = "<section class=\"block \(band(block))\">\n"
        if style.includesSource {
            // Tagged with the source language so a screen reader does not
            // read Chinese with an English voice.
            output += "<div class=\"source\" lang=\"\(sourceLanguage)\">"
                + escape(block.source.text) + "</div>\n"
        }
        output += "<div class=\"target\">" + tag(for: block.source.kind)
            .replacingOccurrences(of: "%@", with: escape(english))
            + "</div>\n"

        if block.confidence.band != .high {
            output += "<p class=\"note\">"
                + escape(block.confidence.band.label) + " — "
                + escape(block.confidence.reasons.joined(separator: "; "))
                + "</p>\n"
        }

        if style.includesWorking {
            output += "<details class=\"working\">"
                + "<summary>How this block was read</summary><dl>"
            for (reader, text) in block.source.candidates.sorted(by: {
                $0.key.rawValue < $1.key.rawValue
            }) {
                output += "<dt>" + escape(reader.displayName) + "</dt><dd>"
                    + escape(text) + "</dd>"
            }
            output += "<dt>Settled</dt><dd>"
                + escape(block.source.settlement.summary) + "</dd>"
            if block.wasRevised {
                output += "<dt>First draft</dt><dd>"
                    + escape(block.firstDraft) + "</dd>"
            }
            for finding in block.findings {
                output += "<dt>Check</dt><dd>"
                    + escape(finding.message) + "</dd>"
            }
            output += "</dl></details>\n"
        }
        output += "</section>\n"
        return output
    }

    private static func tag(for kind: BlockKind) -> String {
        switch kind {
        case .heading: return "<h3>%@</h3>"
        case .listItem: return "<ul><li>%@</li></ul>"
        case .pageFurniture: return "<p class=\"furniture\">%@</p>"
        default: return "<p>%@</p>"
        }
    }

    private static func band(_ block: TranslatedBlock) -> String {
        switch block.confidence.band {
        case .high: return "agreed"
        case .check: return "look"
        case .low: return "human"
        }
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Deliberately plain, and readable on paper: an export of a contract or
    /// a medical letter gets printed far more often than it gets admired.
    static let stylesheet = """
        :root { color-scheme: light dark; }
        body {
          font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          max-width: 62rem; margin: 0 auto; padding: 2rem 1.5rem 6rem;
        }
        header { border-bottom: 1px solid rgba(128,128,128,.35);
          padding-bottom: 1rem; margin-bottom: 2rem; }
        h1 { font-size: 1.6rem; margin: 0 0 .5rem; }
        .provenance { font-size: .8rem; opacity: .75; margin: 0; }
        h2.page { font-size: .75rem; text-transform: uppercase;
          letter-spacing: .08em; opacity: .6; margin: 2.5rem 0 .75rem; }
        .block { margin: 0 0 1.25rem; padding-left: .75rem;
          border-left: 3px solid transparent; }
        .block.look { border-left-color: #c8951b; }
        .block.human { border-left-color: #c0392b; }
        .source { font-size: .95rem; opacity: .7; margin-bottom: .35rem; }
        .target p, .target h3, .target li { margin: 0; }
        .target h3 { font-size: 1.15rem; }
        .furniture { font-size: .8rem; opacity: .6; }
        .note { font-size: .8rem; margin: .35rem 0 0; color: #a1621b; }
        .human .note { color: #b0392b; }
        .working { font-size: .8rem; margin-top: .4rem; opacity: .8; }
        .working dt { font-weight: 600; margin-top: .4rem; }
        .working dd { margin: 0 0 0 1rem; }
        @media (min-width: 60rem) {
          body.bilingual .block, body.audit .block {
            display: grid; grid-template-columns: 1fr 1fr;
            gap: 0 1.5rem; align-items: start;
          }
          body.bilingual .note, body.audit .note,
          body.bilingual .working, body.audit .working {
            grid-column: 1 / -1;
          }
          .source { margin-bottom: 0; }
        }
        @media print {
          body { max-width: none; }
          .block { break-inside: avoid; }
        }
        """
}
