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
    let lines = Fixtures.dense
    guard let image = Fixtures.page(
        lines: lines,
        fontSize: 30,
        startY: 150
    ) else {
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

    let printed = lines.joined()
    let got = chinese.normalizeReading(
        reading.text.replacingOccurrences(of: "\n", with: "")
    )
    let score = TextSimilarity.score(got, printed)

    // The threshold is where it is because of what this model actually does,
    // measured rather than hoped for. It reads a dense page at about 0.70
    // similarity, and the gap is not noise: it rewrites figures into
    // plausible neighbours while producing fluent Chinese around them. 0.6
    // is "it read this page"; anything below it is the failure mode worth
    // catching, which is the model inventing a different document
    // altogether — at a smaller image size it produced a civil judgment,
    // with a case number and a legal representative that were not on the
    // page, and nothing in the output looked wrong.
    report.expect(
        score > 0.6,
        "the model read this page rather than imagining one "
            + "(similarity \(String(format: "%.2f", score)))"
    )
    report.expect(
        chinese.scriptShare(of: got) > 0.6,
        "it transcribed rather than translated or summarized"
    )

    // Figure fidelity is reported, not asserted. The whole reason the
    // recognizer leads and this model only ever checks it is that this
    // number is not 14 of 14 and cannot be made so by asking nicely.
    let wanted = TextIntegrity.numberRuns(in: printed)
    let kept = wanted.filter { Set(TextIntegrity.numberRuns(in: got)).contains($0) }
    print("Figures the model kept: \(kept.count) of \(wanted.count)")
    report.expect(
        !wanted.isEmpty,
        "the fixture has figures in it to lose"
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
