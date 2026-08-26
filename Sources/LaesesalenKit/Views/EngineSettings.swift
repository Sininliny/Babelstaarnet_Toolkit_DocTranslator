import Combine
import DocAgents
import DocCore
import SwiftUI

/// Which engines are doing the work, and what is missing.
///
/// The failure this screen exists to prevent is an app that says
/// "unavailable" and stops. Every unavailable engine here says what is wrong
/// and what would fix it, because most of them are fixed by a settings toggle
/// or a one-time download rather than by a different Mac.
///
/// It is a settings tab now rather than a sheet, and the models it used to
/// open a second sheet for are the tab next door. The two questions really
/// are separate: this screen is about *what is doing the work*, and that one
/// is about *what the app has installed on your disk*.
struct EngineSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    verdict
                    roles
                    Divider()
                    localModelSection
                    Divider()
                    serverSection
                }
                .padding(Metrics.gutter)
            }

            Divider()

            HStack {
                Text(
                    "Laesesalen uses the models that came with macOS. Nothing "
                        + "here needs an account."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button("Check again") {
                    Task { await model.refreshEngines() }
                }
            }
            .padding(Metrics.rowInset)
        }
    }

    /// The answer to the question the reader actually came here with, above
    /// the list rather than inferred from it. Four green ticks and one grey
    /// dash is a list; "this Mac can translate" is an answer.
    private var verdict: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: model.canTranslate
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.title2)
            .foregroundStyle(model.canTranslate ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.canTranslate
                        ? "This Mac can translate a document"
                        : "This Mac cannot translate yet"
                )
                .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(tint: model.canTranslate ? .green : .orange)
    }

    private var detail: String {
        let ready = model.readyEngines.count
        let blocked = model.blockedEngines.count
        if !model.canTranslate {
            return "It needs something that can read a page and something "
                + "that can translate. Each row below says what would fix it."
        }
        if blocked == 0 {
            return "All \(ready) engines are ready."
        }
        return "\(ready) ready. The \(blocked) that are not would each add a "
            + "check the app cannot currently run — the confidence scores "
            + "say so."
    }

    private var roles: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(EngineRole.allCases) { role in
                let statuses = model.statuses.filter { $0.role == role }
                if !statuses.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(role.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(statuses) { status in
                            row(status)
                        }
                    }
                }
            }
        }
    }

    private func row(_ status: EngineStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(status.state))
                .foregroundStyle(color(status.state))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.engineName)
                    if status.isBuiltIn { Badge("built in") }
                }
                switch status.state {
                case .ready:
                    EmptyView()
                case .needsSetup(let problem, let remedy):
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoteLabel(remedy, tone: .action)
                case .unavailable(let problem):
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.engineName), \(spoken(status.state))")
    }

    /// The state said in words, because the only difference between a ready
    /// engine and an absent one used to be the colour of a small circle.
    private func spoken(_ state: EngineStatus.State) -> String {
        switch state {
        case .ready: return "ready"
        case .needsSetup(let problem, let remedy):
            return "needs setup. \(problem) \(remedy)"
        case .unavailable(let problem):
            return "unavailable. \(problem)"
        }
    }

    /// The app's own model: the one thing here the app can install for
    /// itself, and the only engine that does not depend on what Apple has
    /// decided this Mac is eligible for.
    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "Laesesalen's own models",
                model.localModel.explanation
            )

            Toggle(
                "Use Laesesalen's own models",
                isOn: $model.preferences.useLocalModel
            )
            .disabled(model.localModel.stage == .notBuiltIn)

            // What the app decided this Mac should run, said out loud. The
            // choice is otherwise invisible, and a reader who has never been
            // told the app picked a model for them cannot disagree with it.
            if model.localModel.stage != .notBuiltIn {
                Text(machineNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let separate = model.textModelInUse {
                Text(
                    "\(separate.displayName) does the text work: settling "
                        + "disagreements, translating, and reviewing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            switch model.localModel.stage {
            case .notBuiltIn:
                EmptyView()
            case .notFetched:
                VStack(alignment: .leading, spacing: 6) {
                    Button("Get the model") { model.fetchLocalModel() }
                    Text(
                        "One download from Hugging Face. Your document is "
                            + "not part of it and never leaves this Mac."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            case .fetching(let fraction):
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 320)
                    Text("\(Int(fraction * 100))% downloaded")
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
                NoteLabel(problem, tone: .caution)
                Button("Try again") { model.fetchLocalModel() }
            }

            if let problem = model.localModelProblem {
                NoteLabel(problem, tone: .caution)
            }
        }
    }

    /// Why this model and not another one — and, where they differ, what
    /// this Mac could be running instead. A reader who has never been told
    /// the app picked a model for them cannot disagree with the pick.
    private var machineNote: String {
        let inUse = model.visionModelInUse
        let largest = model.recommendedVisionModel
        var note = model.machine.summary
        if model.preferences.localModelID.isEmpty {
            note += model.downloadedModels.contains(inUse.id)
                ? " — using \(inUse.displayName), which is already here."
                : " — so Laesesalen chose \(inUse.displayName)."
        }
        if inUse.id != largest.id {
            note += " This Mac could run \(largest.displayName)."
        }
        return note
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                "A model server you run",
                "For a Mac without Apple Intelligence, or a document a small "
                    + "model reads badly. The address can only be 127.0.0.1."
            )

            Toggle(
                "Also use a model server running on this Mac",
                isOn: $model.preferences.useLocalServer
            )

            if model.preferences.useLocalServer {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 8,
                    verticalSpacing: 6
                ) {
                    GridRow {
                        Text("Address").font(.caption)
                        TextField(
                            "127.0.0.1",
                            text: $model.preferences.serverHost
                        )
                        .frame(width: 110)
                        TextField(
                            "Port",
                            value: $model.preferences.serverPort,
                            format: .number.grouping(.never)
                        )
                        .frame(width: 60)
                        Picker("", selection: $model.preferences.serverDialect) {
                            ForEach(
                                DialectChoice.allCases,
                                id: \.rawValue
                            ) { choice in
                                Text(choice.label).tag(choice.rawValue)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Reads pages").font(.caption)
                        TextField(
                            "vision model",
                            text: $model.preferences.serverVisionModel
                        )
                        .gridCellColumns(3)
                    }
                    GridRow {
                        Text("Text work").font(.caption)
                        TextField(
                            "text model",
                            text: $model.preferences.serverTextModel
                        )
                        .gridCellColumns(3)
                    }
                }
                .font(.callout)

                if case .failure(let error) = model.preferences.endpoint() {
                    NoteLabel(error.localizedDescription, tone: .problem)
                }
            }
        }
    }

    private func symbol(_ state: EngineStatus.State) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .needsSetup: return "arrow.down.circle.fill"
        case .unavailable: return "minus.circle"
        }
    }

    private func color(_ state: EngineStatus.State) -> Color {
        switch state {
        case .ready: return .green
        case .needsSetup: return .orange
        case .unavailable: return .secondary
        }
    }
}

/// The dialects, in a form a picker can bind to a stored string.
enum DialectChoice: String, CaseIterable {
    case ollama
    case openAICompatible

    var label: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }
}
