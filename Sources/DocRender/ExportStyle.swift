import DocCore
import Foundation

/// What an export is for, which decides what it contains.
public enum ExportStyle: String, Sendable, CaseIterable, Identifiable {
    /// The English alone, as a document to read.
    case englishOnly
    /// Source and English side by side, for someone checking the work.
    case bilingual
    /// Bilingual, plus what each reader saw and why each block scored the way
    /// it did. The form to send to whoever has to sign off on it.
    case audit

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .englishOnly: return "Translation only"
        case .bilingual: return "Side by side"
        case .audit: return "Side by side, with the working"
        }
    }

    var includesSource: Bool { self != .englishOnly }
    var includesWorking: Bool { self == .audit }
}

extension TranslatedDocument {
    /// A line every export carries.
    ///
    /// It says three things a translated document should never be without:
    /// which machine did it, that nothing left this one, and how much of it
    /// the app is unsure about. A translation whose provenance is missing
    /// gets treated as though a person made it.
    func provenance() -> [String] {
        var lines = [
            "\(languages.displayName), translated on this Mac by Læsesalen.",
            "Nothing in this document was uploaded anywhere."
        ]
        lines.append("Read by: " + engines.readers.joined(separator: ", "))
        // What the app took the document to be. It belongs with the rest of
        // the provenance because it is provenance: every block in the export
        // was translated on this assumption, and someone reading the English
        // months later cannot infer it from the English.
        if !profile.summary.isEmpty {
            lines.append("Translated as: " + profile.summary)
        }
        if let translator = engines.translator {
            lines.append("Translated by: " + translator)
        }
        if let reviewer = engines.reviewer {
            lines.append("Reviewed by: " + reviewer)
        }
        let attention = needingAttention.count
        let total = blocks.filter(\.source.kind.isTranslatable).count
        if attention == 0 {
            lines.append("All \(total) blocks passed every check.")
        } else {
            lines.append(
                "\(attention) of \(total) blocks need a human eye — they are "
                    + "marked below."
            )
        }
        lines.append(
            finishedAt.formatted(date: .abbreviated, time: .shortened)
        )
        return lines
    }
}
