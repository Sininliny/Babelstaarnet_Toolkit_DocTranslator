import Foundation

/// What the document is, established once and given to every sentence.
///
/// A translator working a sentence at a time is working blind, and the
/// mistakes it makes are invisible in the output. 甲方 is "Party A" in a
/// contract and "the first party" in a news report; 执行 is "enforcement" in
/// a court notice and "execution" in a technical manual; 通知 is a "notice"
/// from an authority and a "notification" in software. Each of those reads
/// perfectly well on its own line, and a document that switches between them
/// halfway down the page reads like two translations stapled together —
/// which is exactly what it is.
///
/// So the document is read before it is translated. One pass over a sample
/// taken from across it produces this — not off the front of it, because the
/// opening page of a long document is its letterhead — and every block
/// afterwards is translated knowing what it belongs to.
public struct DocumentProfile: Sendable, Equatable, Codable {
    /// What kind of document it is, in a few words.
    public var kind: String
    /// What it is about, in one line.
    public var subject: String
    /// How it should sound.
    public var register: String
    /// Terms that must be rendered the same way throughout, source to
    /// target. This is the part that stops page seven disagreeing with page
    /// one.
    public var terms: [String: String]
    /// Anything else the reader of a single sentence would need to know.
    public var notes: [String]

    public init(
        kind: String = "",
        subject: String = "",
        register: String = "",
        terms: [String: String] = [:],
        notes: [String] = []
    ) {
        self.kind = kind
        self.subject = subject
        self.register = register
        self.terms = terms
        self.notes = notes
    }

    public static let unknown = DocumentProfile()

    public var isEmpty: Bool {
        kind.isEmpty && subject.isEmpty && register.isEmpty
            && terms.isEmpty && notes.isEmpty
    }

    /// What the interface shows, so the reader can see what the app decided
    /// the document was. Shown while the work is happening rather than only
    /// at the end, because a wrong profile is a wrong assumption in every
    /// block, the reader is the only one who can see that it is wrong, and an
    /// instruction in the brief overrides it — but only on a run that has not
    /// finished yet.
    public var summary: String {
        var parts: [String] = []
        if !kind.isEmpty { parts.append(kind) }
        if !subject.isEmpty { parts.append(subject) }
        return parts.joined(separator: " — ")
    }

    /// What the document is, handed to every stage that only ever sees one
    /// block of it. Deliberately without the agreed terms: those go with the
    /// block they apply to rather than in front of every block.
    public func guidanceLines() -> [String] {
        var lines: [String] = []
        if !kind.isEmpty {
            lines.append("This document is \(kind).")
        }
        if !subject.isEmpty {
            lines.append("It concerns: \(subject)")
        }
        if !register.isEmpty {
            lines.append("Register: \(register)")
        }
        lines.append(contentsOf: notes)
        return lines
    }

    /// The terms that occur in a given block, which is all a single
    /// translation call needs to be told about. Eight agreed renderings in
    /// front of every block is mostly noise, and a model that has to find the
    /// relevant line will sometimes apply the wrong one.
    ///
    /// Sorted, because a prompt that varies with dictionary order makes two
    /// runs of the same document differ for no reason anyone can see.
    public func terms(appearingIn text: String) -> [(String, String)] {
        terms
            .filter { text.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    /// The same, as instructions — for the reviewer, which is handed a block
    /// and a draft and has nowhere else to be told what the document already
    /// calls things.
    public func termLines(appearingIn text: String) -> [String] {
        terms(appearingIn: text).map {
            "“\($0.0)” is rendered “\($0.1)” everywhere in this document."
        }
    }
}

/// What came immediately before, so a sentence is not translated as though
/// it were the first one on the page.
///
/// Carried as the source *and* the English of the previous block. The English
/// is the important half: it is how the translator knows which rendering of a
/// recurring term it already committed to, without anyone having to write the
/// term down.
public struct TranslationContext: Sendable, Equatable {
    public var previousSource: String?
    public var previousTarget: String?

    public init(previousSource: String? = nil, previousTarget: String? = nil) {
        self.previousSource = previousSource
        self.previousTarget = previousTarget
    }

    public static let none = TranslationContext()

    public var isEmpty: Bool {
        previousSource == nil && previousTarget == nil
    }
}
