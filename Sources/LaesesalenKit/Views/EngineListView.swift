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
struct EngineListView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Engines")
                    .font(.headline)
                Text(
                    "Læsesalen uses the models that came with macOS. Nothing "
                        + "here needs an account or a download from anyone but "
                        + "Apple."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(EngineRole.allCases) { role in
                        let statuses = model.statuses.filter {
                            $0.role == role
                        }
                        if !statuses.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(role.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(statuses) { status in
                                    row(status)
                                }
                            }
                        }
                    }

                    Divider()
                    localModelSection
                    Divider()
                    serverSection
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Check again") {
                    Task { await model.refreshEngines() }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 540)
    }

    private func row(_ status: EngineStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(status.state))
                .foregroundStyle(color(status.state))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.engineName)
                    if status.isBuiltIn {
                        Text("built in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                switch status.state {
                case .ready:
                    EmptyView()
                case .needsSetup(let problem, let remedy):
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                    Text(remedy).font(.caption).foregroundStyle(Color.accentColor)
                case .unavailable(let problem):
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// The app's own model: the one thing here the app can install for
    /// itself, and the only engine that does not depend on what Apple has
    /// decided this Mac is eligible for.
    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Use Læsesalen's own vision model",
                isOn: $model.preferences.useLocalModel
            )
            .disabled(model.localModel.stage == .notBuiltIn)

            Text(model.localModel.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.localModel.stage {
            case .notBuiltIn:
                EmptyView()
            case .notFetched:
                Picker("", selection: $model.preferences.localModelID) {
                    ForEach(LocalModelChoice.all, id: \.id) { choice in
                        Text(
                            model.downloadedModels.contains(choice.id)
                                ? choice.label + " · already here"
                                : choice.label
                        )
                        .tag(choice.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 8) {
                    Button("Get the model") { model.fetchLocalModel() }
                    Text(
                        "One download from Hugging Face. Your document is "
                            + "not part of it and never leaves this Mac."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .fetching(let fraction):
                ProgressView(value: fraction)
                    .frame(maxWidth: 320)
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .ready:
                HStack(spacing: 8) {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                    Spacer()
                    Button("Remove the download") { model.removeLocalModel() }
                        .font(.caption)
                }
            case .failed(let problem):
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                Button("Try again") { model.fetchLocalModel() }
                    .font(.caption)
            }

            if let problem = model.localModelProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Also use a model server running on this Mac",
                isOn: $model.preferences.useLocalServer
            )
            Text(
                "For a Mac without Apple Intelligence, or a document a small "
                    + "model reads badly. The address can only be 127.0.0.1."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.preferences.useLocalServer {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Address").font(.caption)
                        TextField("127.0.0.1", text: $model.preferences.serverHost)
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
                    Label(
                        error.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.red)
                }
            }
        }
    }

    private func symbol(_ state: EngineStatus.State) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .needsSetup: return "arrow.down.circle"
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

/// The models on offer, in a form a picker can bind to a stored string.
///
/// Repeated here rather than read from `DocMLX` because this view is compiled
/// in builds that do not have that module. The identifiers are the ones the
/// catalogue uses; a build without the engine shows the list and cannot act
/// on it, which is the same as every other unavailable engine on this screen.
struct LocalModelChoice {
    let id: String
    let label: String

    static let all = [
        LocalModelChoice(
            id: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            label: "Qwen2.5-VL 3B — balanced (2.3 GB)"
        ),
        LocalModelChoice(
            id: "lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit",
            label: "Qwen3-VL 4B — more accurate (2.9 GB)"
        ),
        LocalModelChoice(
            id: "mlx-community/Qwen2-VL-2B-Instruct-4bit",
            label: "Qwen2-VL 2B — smallest (1.4 GB)"
        )
    ]
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
