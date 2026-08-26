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
    /// The professional field it belongs to, which is what decides how the
    /// things in it are named. See `DocumentField`: it is the difference
    /// between a prescription that says "ibuprofen" and one that says
    /// "Buluofen".
    public var field: DocumentField
    /// What it is about, in one line.
    public var subject: String
    /// The situation the document is part of, in two or three sentences.
    ///
    /// Distinct from `subject`, and the distinction is the whole reason it
    /// exists. The subject names the document; the background is what a
    /// translator asks a client before starting — who these parties are to
    /// each other, what has already happened, what the document is trying to
    /// bring about. A sentence on page six that reads as a bare instruction
    /// is an instruction *about* something, and the translator seeing only
    /// that sentence has no way to know what.
    public var background: String
    /// How it should sound.
    public var register: String
    /// Terms that must be rendered the same way throughout, source to
    /// target. This is the part that stops page seven disagreeing with page
    /// one.
    public var terms: [String: String]
    /// Anything else the reader of a single sentence would need to know.
    public var notes: [String]
    /// The names in the document that were looked up rather than translated.
    ///
    /// Separate from `terms`, and the separation is the point. A term is a
    /// choice between defensible renderings and the document is entitled to
    /// settle it either way; a name has a right answer that is not in the
    /// characters at all, and getting it wrong produces a word that names
    /// nothing. See `ResolvedName`.
    public var names: [ResolvedName]

    public init(
        kind: String = "",
        field: DocumentField = .unknown,
        subject: String = "",
        background: String = "",
        register: String = "",
        terms: [String: String] = [:],
        notes: [String] = [],
        names: [ResolvedName] = []
    ) {
        self.kind = kind
        self.field = field
        self.subject = subject
        self.background = background
        self.register = register
        self.terms = terms
        self.notes = notes
        self.names = names
    }

    public static let unknown = DocumentProfile()

    public var isEmpty: Bool {
        kind.isEmpty && subject.isEmpty && background.isEmpty
            && register.isEmpty && terms.isEmpty && notes.isEmpty
            && names.isEmpty && !field.isKnown
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
        if !background.isEmpty {
            lines.append("Background: \(background)")
        }
        if !register.isEmpty {
            lines.append("Register: \(register)")
        }
        // The field, and what the field requires. Last of the standing
        // guidance and longest, because it is the part that is not a
        // description of the document but a set of rules for writing it: a
        // translator told only that this is a prescription still has to
        // decide what to call the drug, and this is where it is told that
        // the drug has a name rather than a rendering.
        if field.isKnown {
            lines.append(
                "Its field is \(field.promptName). What that field requires:"
            )
            lines.append(contentsOf: field.namingConventions)
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

    /// The looked-up names that occur in a given block. Same rule as the
    /// terms: a block is told about the names that are in it, and about no
    /// others.
    public func names(appearingIn text: String) -> [ResolvedName] {
        names
            .filter { text.contains($0.source) }
            .sorted { $0.source < $1.source }
    }

    /// The names as instructions, for the reviewer.
    public func nameLines(appearingIn text: String) -> [String] {
        names(appearingIn: text).map(\.instruction)
    }

    /// What the app looked up, for the reader and for the record.
    ///
    /// Shown rather than kept, because a name the app got wrong is a word
    /// the reader is about to act on — a dose of the wrong drug — and the
    /// reader is the only participant here who can catch it. A pipeline that
    /// silently substituted "ibuprofen" for something else would be asking
    /// for trust it has not earned.
    public var nameSummary: [String] {
        names.map { "\($0.source) → \($0.rendering)" }
    }
}

/// A name in the document and what it is called in the target language.
///
/// The thing that makes this different from a glossary entry is where the
/// answer comes from. 甲方 has two defensible renderings and the document may
/// settle on either; 布洛芬 has one right answer — "ibuprofen" — which is not
/// derivable from the characters, is not a matter of taste, and cannot be
/// checked by anyone who reads only the English. Spelling it out instead
/// produces "Buluofen": a word in no language, naming no drug, sitting in a
/// sentence that otherwise reads perfectly.
///
/// So a name is looked up once, for the whole document, and carried to every
/// block that contains it — and the basis is carried with it, because a
/// rendering a reader cannot account for is one they have to take on faith.
public struct ResolvedName: Sendable, Equatable, Codable, Identifiable {
    public var id: String { source }
    /// As it is printed in the document.
    public let source: String
    /// What it is called in the target language.
    public let rendering: String
    /// What makes that its name: "its international nonproprietary name",
    /// "the hospital's own English name", "the title the statute is
    /// published under". Given to the model along with the rendering,
    /// because a rule with a reason attached is one it can apply to the near
    /// misses this list does not contain — and shown to the reader, who is
    /// the only one here who can tell a lookup from a guess.
    public let basis: String?

    public init(source: String, rendering: String, basis: String? = nil) {
        self.source = source
        self.rendering = rendering
        self.basis = basis
    }

    public var instruction: String {
        let base = "“\(source)” is called “\(rendering)” in the target "
            + "language; use that, not a transliteration."
        guard let basis, !basis.isEmpty else { return base }
        return base + " (\(basis))"
    }
}
