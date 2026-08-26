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

    /// The name that fits on a control.
    ///
    /// `displayName` is a sentence, and a sentence is right in a list of
    /// three where the reader is choosing between them. It is wrong on a
    /// button, and the button that used to be built out of it read "Save the
    /// same document, in english…" — the sentence lowercased, mid-word, with
    /// the proper noun gone.
    public var shortName: String {
        switch self {
        case .sameDocument: return "Same document"
        case .plainText: return "Just the text"
        case .sideBySide: return "Side by side"
        }
    }

    /// What the save button says. It names the file the reader gets, because
    /// that is the thing they are about to have to find again.
    public var saveTitle: String {
        switch self {
        case .sameDocument: return "Save PDF…"
        case .plainText: return "Save text…"
        case .sideBySide: return "Save web page…"
        }
    }

    /// The picture on the card. A mode is chosen at a glance and confirmed by
    /// reading, which is the order these are laid out in.
    public var symbol: String {
        switch self {
        case .sameDocument: return "doc.on.doc"
        case .plainText: return "text.alignleft"
        case .sideBySide: return "rectangle.split.2x1"
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
