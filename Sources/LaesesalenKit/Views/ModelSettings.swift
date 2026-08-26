import Combine
import DocCore
import SwiftUI

/// The models on this Mac: which one is doing what, which would suit the
/// machine better, and how to get the disk space back.
///
/// This screen exists because the app installs things. Everything else in
/// Laesesalen is either part of macOS or a file the reader opened; the models
/// are gigabytes the app fetched and put somewhere, and an app that can do
/// that and cannot show you what it did — or undo it — is a bad guest.
///
/// The three questions it answers are the three a reader actually has. Which
/// model is being used, and is it the right size for this Mac. What would it
/// cost to change. And what is down there that nothing is using.
struct ModelSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    machine
                    if !model.hasLocalEngine { engineMissing }
                    readerSection
                    Divider()
                    textSection
                    Divider()
                    storageSection
                }
                .padding(Metrics.gutter)
            }

            Divider()

            HStack {
                Text(
                    "Downloaded once from Hugging Face and run on this Mac "
                        + "from then on. No document is part of that request."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
            }
            .padding(Metrics.rowInset)
        }
    }

    /// The machine, stated, so the recommendation below is something the
    /// reader can check rather than something they have to take.
    private var machine: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "memorychip")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac")
                    .font(.callout.weight(.semibold))
                Text(model.machine.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "How large a model you are offered is decided by this, "
                        + "not by us."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    /// The build that has no engine in it, said at the top rather than
    /// discovered by pressing things.
    ///
    /// This screen listed five models, priced them, marked one as suiting
    /// this Mac and offered a button to fetch it — in a build that cannot run
    /// any of them. Pressing the button put one line of explanation at the
    /// very bottom of the scroll view, under the disk listing, three sections
    /// away from the button that had just done nothing.
    ///
    /// The models are still listed here, because this build must still be
    /// able to show what an earlier one downloaded and give the space back.
    /// What it must not do is pretend it can fetch them.
    private var engineMissing: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                "This build cannot run a model of its own",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.orange)

            Text(
                "MLX compiles Metal kernels, and the Metal compiler comes "
                    + "with Xcode rather than with the Command Line Tools. "
                    + "Nothing below can be downloaded until the app is "
                    + "built with the engine in it — the list is here so "
                    + "this build can still show what is on the disk and "
                    + "give the space back."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("make app-mlx")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.14))
                )

            Text(
                "Everything else in Laesesalen works: Apple Vision reads the "
                    + "page and Apple Translation translates it."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: .orange)
    }

    // MARK: - Reading pages

    private var readerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                "Reads pages",
                "The second reader: it looks at the page image beside Apple "
                    + "Vision, and their mistakes are of different kinds."
            )
            ForEach(LocalModelCatalogue.visionModels) { spec in
                row(spec, inUse: spec.id == model.visionModelInUse.id) {
                    model.use(visionModel: spec)
                }
            }
        }
    }

    // MARK: - The text work

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                "Text work",
                "Settling disagreements, reading the document, translating, "
                    + "reviewing. The page reader does all of this too, and "
                    + "on most Macs that is the right arrangement — a second "
                    + "model is a second download and a second few gigabytes "
                    + "held in memory at the same time."
            )
            sharedRow
            ForEach(LocalModelCatalogue.textModels) { spec in
                row(spec, inUse: spec.id == model.textModelInUse?.id) {
                    model.use(textModel: spec)
                }
            }
        }
    }

    /// The default, and it is a real choice rather than the absence of one.
    private var sharedRow: some View {
        let chosen = model.textModelInUse == nil
        return Button {
            model.use(textModel: nil)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName: chosen
                        ? "largecircle.fill.circle"
                        : "circle"
                )
                .foregroundStyle(chosen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("The same model as the page reader")
                            .foregroundStyle(.primary)
                        Badge("no extra download")
                    }
                    Text(
                        "Nothing else held in memory. A vision-language model "
                            + "is a language model with an image encoder on "
                            + "it, so the text roles cost nothing extra."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }

    // MARK: - One model

    private func row(
        _ spec: LocalModelSpec,
        inUse: Bool,
        use: @escaping () -> Void
    ) -> some View {
        let onDisk = model.downloadedModels.contains(spec.id)
        let obstacle = model.obstacle(to: spec)
        let recommended = spec.role == .vision
            ? spec.id == model.recommendedVisionModel.id
            : spec.id == model.recommendedTextModel?.id
        let stage = stage(of: spec)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: inUse ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(inUse ? Color.accentColor : .secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.displayName)
                    Text(spec.approximateSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if recommended { Badge("suits this Mac", tint: .green) }
                    if onDisk { Badge("on this Mac") }
                }
                Text(spec.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // What is in the way, rather than a row that is silently
                // dead: most of these are fixed by a smaller model or by
                // removing one that is not being used.
                if let obstacle {
                    NoteLabel(obstacle, tone: .caution)
                }
                if let stage {
                    progress(stage)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if !inUse, obstacle == nil {
                    Button("Use this", action: use)
                }
                // One press, on any row, whether or not this model is the
                // one currently chosen: choosing it is what getting it
                // means. Absent while it is arriving, because the bar in the
                // row is already saying so.
                if model.hasLocalEngine, obstacle == nil, !onDisk,
                   !isBusy(stage) {
                    Button(hasFailed(stage) ? "Try again" : "Get it") {
                        model.get(spec)
                    }
                }
                if onDisk {
                    Button("Remove") { model.removeModel(id: spec.id) }
                }
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(inUse ? [.isSelected] : [])
    }

    /// Where a given model has got to, where it is one of the two the app is
    /// currently holding. The others have no state to be in.
    private func stage(of spec: LocalModelSpec) -> LocalModelStatus.Stage? {
        if model.localModel.modelID == spec.id { return model.localModel.stage }
        if model.textModel.modelID == spec.id { return model.textModel.stage }
        return nil
    }

    /// What is happening to this model, in the row for this model.
    ///
    /// Every stage, not only the download. The screen used to draw a bar for
    /// `fetching` and nothing at all for the rest, which left the two longest
    /// silences in the app unexplained: a four-gigabyte model spends a minute
    /// being loaded into memory after the bar has reached the end, and a
    /// download that failed said so in one line at the foot of the page,
    /// below the disk listing, where nobody watching the row would find it.
    @ViewBuilder
    private func progress(_ stage: LocalModelStatus.Stage) -> some View {
        switch stage {
        case .notBuiltIn, .notFetched:
            EmptyView()
        case .fetching(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 200)
                // A download that has not reported a byte yet is a download
                // that has started, and "0%" reads like one that has stalled.
                Text(
                    fraction > 0
                        ? "\(Int(fraction * 100))% downloaded"
                        : "Starting…"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        case .loading:
            Label {
                Text("Loading into memory…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.green)
        case .failed(let problem):
            NoteLabel(problem, tone: .problem)
        }
    }

    /// Arriving, in either of the two senses. The button stands down while it
    /// is, because the row is already saying what is happening.
    private func isBusy(_ stage: LocalModelStatus.Stage?) -> Bool {
        switch stage {
        case .fetching, .loading: return true
        default: return false
        }
    }

    private func hasFailed(_ stage: LocalModelStatus.Stage?) -> Bool {
        if case .failed = stage { return true }
        return false
    }

    // MARK: - What is on the disk

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                "On this Mac",
                "Where the weights are, and what they are taking."
            )

            if model.installedModels.isEmpty {
                Text("Nothing downloaded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.installedModels) { installed in
                HStack(spacing: 8) {
                    Image(
                        systemName: installed.isComplete
                            ? "internaldrive"
                            : "exclamationmark.arrow.circlepath"
                    )
                    .foregroundStyle(
                        installed.isComplete ? .secondary : Color.orange
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(installed.displayName)
                        if installed.isOrphan {
                            // The one kind of download nothing else on any
                            // screen would ever mention again.
                            Text(
                                "This version of Laesesalen does not offer "
                                    + "this model."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else if !installed.isComplete {
                            Text("An interrupted download, not a model.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(installed.size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Remove") { model.removeModel(id: installed.id) }
                        .controlSize(.small)
                }
            }

            let spare = model.unusedModels
            if !spare.isEmpty {
                Button {
                    model.removeUnusedModels()
                } label: {
                    Label(
                        "Remove the \(spare.count) nothing is using — "
                            + ByteCountFormatter.string(
                                fromByteCount: model.unusedModelBytes,
                                countStyle: .file
                            ),
                        systemImage: "trash"
                    )
                }
            }

            HStack(spacing: 6) {
                Text(LocalModelStorage.defaultRoot.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [LocalModelStorage.defaultRoot]
                    )
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show the weights in the Finder")
                .accessibilityLabel("Show in Finder")
            }

            if let problem = model.localModelProblem {
                NoteLabel(problem, tone: .caution)
            }
        }
    }
}
