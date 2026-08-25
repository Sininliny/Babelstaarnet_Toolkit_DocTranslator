import CoreImage
import DocCore
import Foundation
import Vision

/// The page as Apple Vision reads it.
///
/// The recognition level is `.accurate` and is not configurable. Vision's fast
/// level does not recognize Chinese at all, and where a level is offered for
/// another script the fast one has been measured to drop diacritics while
/// reporting unchanged confidence — a silent corruption no routing gate can
/// detect. Speed is not worth a character that changes the word.
///
/// Preparation is a *retry*, never a first pass, for the same reason it is in
/// the parent project: a contrast pass tuned hard enough to rescue a grey scan
/// can wreck a clean one, and running it second means it can only ever add
/// readings, never take them away.
public struct VisionTranscriber: PageTranscriber {
    public let reader: PageReader = .visionOCR
    /// The share of a page's lines that must come back with usable confidence
    /// before the raw reading is accepted without a retry.
    private let confidenceFloor: Double

    public init(confidenceFloor: Double = 0.3) {
        self.confidenceFloor = confidenceFloor
    }

    public func transcribe(
        _ page: PageImage,
        language: SourceLanguage
    ) async throws -> PageReading {
        let started = Date()
        var lines = try await recognize(page.image, language: language)

        if needsRetry(lines) {
            if let prepared = PagePreparation.separated(page.image) {
                let retried = try await recognize(prepared, language: language)
                if score(retried) > score(lines) { lines = retried }
            }
        }

        let normalized = lines.map { line in
            RecognizedLine(
                text: language.normalizeReading(line.text),
                box: line.box,
                confidence: line.confidence
            )
        }

        return PageReading(
            reader: reader,
            pageIndex: page.index,
            blocks: BlockAssembly.blocks(
                from: normalized,
                pageIndex: page.index,
                language: language
            ),
            seconds: Date().timeIntervalSince(started)
        )
    }

    private func needsRetry(_ lines: [RecognizedLine]) -> Bool {
        if lines.isEmpty { return true }
        let weak = lines.filter { $0.confidence < confidenceFloor }
        return Double(weak.count) / Double(lines.count) > 0.3
    }

    /// Characters read, weighted by how sure the recognizer was. Comparing
    /// two passes on this rather than on line count is what stops a retry
    /// that found more, worse lines from replacing a good reading.
    private func score(_ lines: [RecognizedLine]) -> Double {
        lines.reduce(0) { $0 + Double($1.text.count) * $1.confidence }
    }

    private func recognize(
        _ image: CGImage,
        language: SourceLanguage
    ) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            // Vision's handler is synchronous and CPU-bound; running it on
            // the calling actor's thread would stall whatever else that actor
            // is doing, which in this app is the interface.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages =
                    language.visionRecognitionLanguages
                request.usesLanguageCorrection = true
                // A document is not a screenshot: the smallest real text on a
                // page of dense type is a footnote, and asking Vision to
                // consider text smaller than this only slows it down.
                request.minimumTextHeight = 0.004

                do {
                    try VNImageRequestHandler(
                        cgImage: image,
                        orientation: .up
                    ).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results ?? []
                continuation.resume(returning: observations.compactMap(Self.line))
            }
        }
    }

    /// Vision reports normalized coordinates with the origin at the bottom
    /// left. Every other coordinate system in this app puts it at the top, so
    /// the flip happens here, once.
    static func line(from observation: VNRecognizedTextObservation) -> RecognizedLine? {
        guard let candidate = observation.topCandidates(1).first else {
            return nil
        }
        let box = observation.boundingBox
        return RecognizedLine(
            text: candidate.string,
            box: BlockBox(
                x: box.origin.x,
                y: 1 - box.origin.y - box.size.height,
                width: box.size.width,
                height: box.size.height
            ),
            confidence: Double(candidate.confidence)
        )
    }
}

/// The retry pass: what to do with a page the recognizer could not read.
enum PagePreparation {
    /// Grey, stretched, and thresholded.
    ///
    /// Aimed at the two cases that actually defeat Vision on documents — a
    /// photographed page with uneven lighting, and a faded or low-contrast
    /// scan — rather than at the general problem of hard images. Colour is
    /// discarded first because a red seal over black text is one object to a
    /// luminance threshold and two to a colour one.
    static func separated(_ image: CGImage) -> CGImage? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let input = CIImage(cgImage: image)

        guard let mono = CIFilter(name: "CIPhotoEffectMono") else { return nil }
        mono.setValue(input, forKey: kCIInputImageKey)
        guard let grey = mono.outputImage else { return nil }

        guard let controls = CIFilter(name: "CIColorControls") else {
            return nil
        }
        controls.setValue(grey, forKey: kCIInputImageKey)
        controls.setValue(1.6, forKey: kCIInputContrastKey)
        controls.setValue(0.05, forKey: kCIInputBrightnessKey)
        guard let stretched = controls.outputImage else { return nil }

        return context.createCGImage(stretched, from: stretched.extent)
    }
}
