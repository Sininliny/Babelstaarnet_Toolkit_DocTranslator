import DocCore
import Foundation
import LanguageChinese
#if MLXEngine
import CoreGraphics
import DocMLX
#endif

/// The app's own vision-language model, actually reading a page.
///
/// Kept out of `make test` behind a flag, for two reasons that are both about
/// what a check is for. It downloads a couple of gigabytes the first time,
/// and a suite that cannot be run on a fresh clone without a long download is
/// a suite people stop running. And it needs a GPU and thirty seconds a page,
/// where every other check in this project is instant.
///
/// Run it with `swift run --traits MLXEngine Checks --local-model`.
func runLocalModelChecks(_ report: Report) async {
    report.begin("local model")

    #if !MLXEngine
    report.expect(
        false,
        "this binary was built without the MLX engine — build with "
            + "--traits MLXEngine"
    )
    #else
    let chinese = SimplifiedChinese.language
    let lines = [
        "本协议自二零二四年三月十五日起生效。",
        "合同期限为三年，罚款为5000元。"
    ]
    guard let image = Fixtures.page(lines: lines) else {
        report.expect(false, "the fixture page could not be drawn")
        return
    }

    let store = MLXModelStore()
    let model = await store.model
    print("Preparing \(model.displayName) (\(model.approximateSize))…")

    do {
        _ = try await store.prepare()
    } catch {
        report.expect(
            false,
            "the model could not be prepared: \(error.localizedDescription)"
        )
        return
    }
    report.expect(await store.currentState().isReady, "the model loads")

    let started = Date()
    let reading = try? await MLXVisionReader(store: store).transcribe(
        PageImage(
            index: 0,
            image: image,
            pointSize: CGSize(width: image.width, height: image.height)
        ),
        language: chinese
    )
    let seconds = Date().timeIntervalSince(started)

    guard let reading, !reading.isEmpty else {
        report.expect(false, "the model returned nothing for a clean page")
        return
    }
    print("Read the page in \(String(format: "%.1f", seconds))s")
    print("Got: \(reading.text)")

    let score = TextSimilarity.score(
        chinese.normalizeReading(reading.text),
        lines.joined()
    )
    // Deliberately not an exact match. A language model transcribing a page
    // is allowed to differ from it in ways a recognizer is not — it may drop
    // a full stop or normalize a form — and a check that demands perfection
    // fails on a model update rather than on a regression. What must hold is
    // that it read the page rather than imagined one.
    report.expect(
        score > 0.75,
        "the model recovers what was printed (similarity \(score))"
    )
    report.expect(
        reading.text.contains("5000"),
        "figures survive the model: got “\(reading.text.prefix(60))”"
    )
    report.expect(
        chinese.scriptShare(of: reading.text) > 0.6,
        "it transcribed rather than translated"
    )

    // The text roles, on the same model.
    let agent = MLXTextAgent(store: store, name: model.displayName)
    let choice = try? await agent.answer(
        instructions: AgentPrompts.adjudicationInstructions(for: chinese),
        prompt: AgentPrompts.adjudicationPrompt(
            contextBefore: nil,
            candidateA: "合同期限为三年。",
            candidateB: "合同期限为三车。"
        ),
        expecting: .choice(AgentPrompts.adjudicationChoices)
    )
    report.equal(
        choice,
        AgentPrompts.choiceA,
        "the adjudicator picks the reading that makes sense"
    )
    #endif
}
