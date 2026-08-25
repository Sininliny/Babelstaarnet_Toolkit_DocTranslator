import DocCore
import Foundation

/// What the reader wants back.
///
/// The same pipeline produces all of these — the readers, the adjudication,
/// the translation and the checks do not change — but what they are *for*
/// does, and the difference is worth choosing before the work starts rather
/// than discovering at the end.
public enum OutputMode: String, Sendable, CaseIterable, Identifiable {
    /// The document again, looking like itself, with the Chinese replaced by
    /// English in place. Stamps, photographs, tables, letterheads and layout
    /// all stay; only the text changes.
    case sameDocument
    /// The words alone, in reading order. No layout, no markup, no notes —
    /// text to paste into something else.
    case plainText
    /// Both languages, block by block, with the app's working shown.
    case sideBySide

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sameDocument: return "The same document, in English"
        case .plainText: return "Just the text"
        case .sideBySide: return "Side by side"
        }
    }

    public var explanation: String {
        switch self {
        case .sameDocument:
            return "A PDF that looks like the original — background, stamps "
                + "and layout kept — with the Chinese replaced in place."
        case .plainText:
            return "Plain text in reading order, ready to paste elsewhere."
        case .sideBySide:
            return "The Chinese and the English together, with what each "
                + "reader saw."
        }
    }

    public var fileExtension: String {
        switch self {
        case .sameDocument: return "pdf"
        case .plainText: return "txt"
        case .sideBySide: return "html"
        }
    }
}
