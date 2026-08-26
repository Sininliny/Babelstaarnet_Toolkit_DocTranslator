import Foundation

/// The field a document belongs to, and what that field calls things.
///
/// A name is the part of a document a translator cannot reason its way to.
/// 布洛芬 is three characters that spell out, syllable by syllable, as
/// "buluofen", and a model translating a sentence at a time will write
/// exactly that: a word that is not English, that names nothing, and that
/// looks enough like a translation that a reader who cannot read the source
/// has no way to tell. The word it wanted was "ibuprofen" — the drug's
/// international nonproprietary name, which is what the pharmacy label says
/// and what the Chinese name was itself coined from. Nothing in the
/// characters leads there. It is a lookup, not a rendering.
///
/// The same failure has a different right answer in every field. In law it is
/// the statute's official English title; in scholarship the title the work was
/// published under; for a hospital or a ministry, the English name the body
/// uses for itself; in medicine the nonproprietary name. A translator who
/// knows which of those they are holding gets it right far more often than
/// one who does not, and that is the whole reason this exists: the field is
/// established once, when the document is read, and its conventions are then
/// handed to every stage that only ever sees one block.
///
/// So this is not a category for the interface to display. It is the
/// difference between a prescription that says "ibuprofen" and one that says
/// "Buluofen" — a document that is dangerous rather than merely wrong.
public enum DocumentField: String, Sendable, Equatable, Codable, CaseIterable {
    case medicine
    case law
    case finance
    case engineering
    case scholarship
    case government
    case commerce
    case personal
    /// Nothing in the document said, and nothing may be assumed. The general
    /// naming rule still applies; none of the specific ones do, because a
    /// specific convention applied to the wrong field is worse than no
    /// convention at all.
    case unknown

    /// What the interface shows.
    public var label: String {
        switch self {
        case .medicine: return "Medicine"
        case .law: return "Law"
        case .finance: return "Finance"
        case .engineering: return "Engineering"
        case .scholarship: return "Scholarship"
        case .government: return "Government"
        case .commerce: return "Business"
        case .personal: return "Personal"
        case .unknown: return "Unknown"
        }
    }

    /// How the field is named to a model, and how it is offered to the reader
    /// when the app has to ask.
    public var promptName: String {
        switch self {
        case .medicine: return "medicine and health care"
        case .law: return "law"
        case .finance: return "finance and accounting"
        case .engineering: return "engineering and technology"
        case .scholarship: return "scholarship and research"
        case .government: return "government and administration"
        case .commerce: return "business and trade"
        case .personal: return "personal correspondence"
        case .unknown: return "no particular field"
        }
    }

    /// The one line that says what picking this field commits the translator
    /// to. Shown beside the label where the reader is asked to choose, so the
    /// choice is between consequences rather than between words.
    public var consequence: String {
        switch self {
        case .medicine:
            return "Drugs by their generic name, doses copied exactly"
        case .law:
            return "Statutes and courts by their official English names"
        case .finance:
            return "Standard accounting English, figures copied exactly"
        case .engineering:
            return "Standards and part numbers exactly as printed"
        case .scholarship:
            return "Cited works and institutions by their published names"
        case .government:
            return "Bodies and documents by their official English names"
        case .commerce:
            return "Companies and products by their registered names"
        case .personal:
            return "Names transliterated, the tone of the original kept"
        case .unknown:
            return "No field-specific conventions applied"
        }
    }

    /// How this field names things, as instructions.
    ///
    /// Written without an example from any one source language on purpose:
    /// these are conventions of a profession, not of a script, and the app is
    /// meant to gain a language by gaining a language pack rather than by
    /// editing this file. What the wrong answer looks like — a name spelled
    /// out in the source's own romanization — is a fact about the script, and
    /// lives in the pack with the rest of them.
    public var namingConventions: [String] {
        switch self {
        case .medicine:
            return [
                "Name a drug by its international nonproprietary name — the "
                    + "generic name a pharmacist would recognize. Keep a "
                    + "brand name as printed.",
                "Use standard clinical English for conditions, procedures, "
                    + "and anatomy rather than a literal rendering of the "
                    + "source's words.",
                "Doses, strengths, frequencies, routes, and units are copied "
                    + "exactly. Never convert or round one.",
                "Name a hospital, department, or clinic by the English name "
                    + "it uses for itself where it has one."
            ]
        case .law:
            return [
                "Name a statute, regulation, or judicial interpretation by "
                    + "its official English title.",
                "Name a court, prosecuting authority, ministry, or bureau by "
                    + "the English name that body uses for itself.",
                "Case numbers, article numbers, and clause numbers are "
                    + "copied exactly.",
                "A party the document defines keeps that name in every "
                    + "sentence that mentions it."
            ]
        case .finance:
            return [
                "Name a company by its registered English name where it has "
                    + "one.",
                "Use standard accounting English for line items, instruments, "
                    + "and statements.",
                "Figures, currencies, and units are copied exactly. Name the "
                    + "currency; never convert it."
            ]
        case .engineering:
            return [
                "Name a standard, specification, or code by its designation, "
                    + "exactly as printed.",
                "Use the industry's English for components, materials, and "
                    + "processes rather than a literal rendering.",
                "Model numbers, tolerances, and units are copied exactly."
            ]
        case .scholarship:
            return [
                "Name a cited work by the title it was published under in "
                    + "the target language, where it has one.",
                "Name a university, institute, or journal by the English "
                    + "name it uses for itself.",
                "Keep an author's name in the form their published work uses."
            ]
        case .government:
            return [
                "Name a ministry, bureau, commission, or office by the "
                    + "English name it uses for itself.",
                "Name a policy, plan, or measure by its official English "
                    + "title.",
                "Document numbers, seals, and official titles are copied or "
                    + "rendered exactly, never paraphrased."
            ]
        case .commerce:
            return [
                "Name a company or brand by its registered English name "
                    + "where it has one.",
                "Keep product names, models, and specifications as they are "
                    + "marketed.",
                "A party the document defines keeps that name in every "
                    + "sentence that mentions it."
            ]
        case .personal:
            return [
                "A private person's name has no official English form: "
                    + "transliterate it, and keep one spelling throughout.",
                "Place names take their usual English spelling.",
                "Keep the tone of the original. This is not an official "
                    + "document and must not be made to sound like one."
            ]
        case .unknown:
            return []
        }
    }

    public var isKnown: Bool { self != .unknown }

    /// The fields the reader is offered when the app cannot tell. Everything
    /// but `unknown`, which is not a choice anyone can make — a reader who
    /// does not know says so with "I'm not sure", and that answer means
    /// something different from "no field".
    public static var choices: [DocumentField] {
        allCases.filter(\.isKnown)
    }

    /// What the app asks when it cannot work the field out for itself.
    ///
    /// Asked rather than defaulted, and asked *before* the first block is
    /// translated, because a field is not a preference: it is the difference
    /// between a substance named by the name a pharmacist would know and one
    /// named by what its characters sound like. The reader knows what they
    /// dropped on the app. It is one click, and the alternative is a whole
    /// document translated with no conventions at all.
    ///
    /// The options say what choosing them commits the translator to, because
    /// "Medicine" and "Law" are labels a reader could pick between without
    /// learning anything about what happens next.
    public static let question = "What field is this document from?"

    public static var clarification: ClarificationQuestion {
        ClarificationQuestion(
            question: question,
            options: choices.map {
                ClarificationOption(
                    label: "\($0.label) — \($0.consequence)",
                    guidance: $0.guidance
                )
            } + [.unsure]
        )
    }

    /// What an answer tells the translator. The conventions themselves,
    /// because a brief entry reading "this is a medical document" leaves the
    /// model exactly where it was.
    var guidance: String {
        (["This document is from \(promptName)."] + namingConventions)
            .joined(separator: " ")
    }

    /// The field a model's answer names, or the one a description of the
    /// document implies.
    ///
    /// Matched on stems rather than whole words because the answer is free
    /// text and arrives in every form: "medicine", "medical record", "a
    /// prescription", "clinical". A model asked for one word will give a
    /// phrase often enough that a lookup table of exact answers would be a
    /// table of the answers seen so far.
    ///
    /// The order the cases are declared in is the order they are tried in,
    /// and it decides the overlaps: a regulation is law before it is
    /// government, an invoice is finance before it is trade. Both readings
    /// are defensible, and picking one deterministically matters more than
    /// which one — a document whose field changes between two runs changes
    /// every name in it.
    public init(describing description: String) {
        let text = description.lowercased()
        for field in DocumentField.choices
        where field.stems.contains(where: text.contains) {
            self = field
            return
        }
        self = .unknown
    }

    /// What the field sounds like when it is being described rather than
    /// named.
    var stems: [String] {
        switch self {
        case .medicine:
            return [
                "medic", "clinic", "health", "pharma", "prescription",
                "hospital", "patient", "diagnos", "nursing", "surgery",
                "discharge summary", "lab report", "laboratory report"
            ]
        case .law:
            return [
                "law", "legal", "court", "judic", "judgment", "judgement",
                "litig", "contract", "statut", "regulat", "attorney",
                "arbitrat", "notari", "notary", "affidavit", "plaintiff",
                "defendant", "enforcement notice"
            ]
        case .finance:
            return [
                "financ", "account", "audit", "bank", "tax", "invoice",
                "invest", "insur", "balance sheet", "payroll"
            ]
        case .engineering:
            return [
                "engineer", "technic", "manufactur", "construct", "industr",
                "specification", "software", "chemic", "mechanic",
                "electric", "datasheet", "data sheet", "manual"
            ]
        case .scholarship:
            return [
                "academ", "research", "scholar", "thesis", "dissertation",
                "journal", "scientific", "universit", "conference paper",
                "transcript of records"
            ]
        case .government:
            return [
                "government", "administrat", "ministr", "municipal",
                "policy", "public notice", "immigration", "visa",
                "civil affairs", "household register", "certificate"
            ]
        case .commerce:
            return [
                "commerc", "business", "market", "product", "sales",
                "company profile", "trade", "advertis", "brochure",
                "purchase order"
            ]
        case .personal:
            return [
                "personal", "letter", "famil", "private", "diary",
                "correspond", "postcard", "memoir"
            ]
        case .unknown:
            return []
        }
    }
}
