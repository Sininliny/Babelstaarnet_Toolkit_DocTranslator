import Foundation

/// A document, one page at a time.
///
/// Pages are rendered on demand rather than up front. A fifty-page PDF
/// rasterized at a resolution dense Chinese type actually needs is well over a
/// gigabyte of bitmaps, and the pipeline only ever looks at one page at a
/// time; holding the other forty-nine buys nothing.
public protocol PageProvider: Sendable {
    var source: DocumentSource { get }
    func page(at index: Int) throws -> PageImage
    /// The text the file already carries, where it carries any. Not a
    /// recognition result and not a guess — for a born-digital PDF this is
    /// the document's own copy of its words.
    ///
    /// Takes the language because the characters have to be assembled into
    /// the same units the other readers produce, and what a sentence is is a
    /// fact about the language. Assembled with a placeholder instead, a
    /// born-digital PDF hands the reconciler paragraph-sized blocks to
    /// compare against everyone else's sentences.
    func textLayer(at index: Int, language: SourceLanguage) -> PageReading?
}
