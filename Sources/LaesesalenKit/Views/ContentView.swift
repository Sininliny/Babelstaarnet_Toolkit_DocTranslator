import Combine
import DocCore
import DocIngest
import SwiftUI
import UniformTypeIdentifiers

/// Which tab of the settings window is showing.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case engines
    case models
    case defaults

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .engines: return "Engines"
        case .models: return "Models"
        case .defaults: return "Defaults"
        }
    }

    var symbol: String {
        switch self {
        case .engines: return "gearshape.2"
        case .models: return "internaldrive"
        case .defaults: return "text.quote"
        }
    }
}

/// What is open, as distinct from what the app is doing.
///
/// A view's own state, held in an object because `@State` is a macro whose
/// plugin ships with Xcode — see `PrivacyLedger` for why this project stays
/// on `ObservableObject` throughout. It is owned by the app rather than by
/// the window now, because the menu bar opens these too, and a menu is not
/// inside the view hierarchy that used to hold them.
public final class WindowState: ObservableObject {
    @Published public var showsBrief = false
    /// The whole ledger, every line of it.
    @Published public var showsPrivacy = false
    /// The one-paragraph answer, hanging off the lock in the corner. Most of
    /// the time the answer is "nothing has left this Mac", and making someone
    /// open a window with a seven-column table in it to be told that is
    /// making them work for the reassurance the app exists to give.
    @Published public var showsPrivacySummary = false
    @Published public var settingsTab = SettingsTab.engines

    public init() {}
}

/// The whole window.
///
/// One screen, three states, no navigation. A document translator is a thing
/// you point at a file and read the answer from; anything the reader has to
/// find their way around is in the way.
///
/// What changed: the two panels that are about the *app* rather than about
/// this document — which engines exist, what has been downloaded — used to be
/// sheets, one of them opening a second sheet on top of itself. A sheet is a
/// question the app is asking, and neither of those was a question; both were
/// reference. They are a settings window now, at ⌘, where a Mac user already
/// looks for them, and the window behind stays usable while they are open.
public struct ContentView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var window: WindowState

    public init(model: AppModel, window: WindowState) {
        self.model = model
        self.window = window
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle:
                DropTargetView(model: model, window: window)
            case .working:
                WorkingView(model: model)
            case .finished(let document):
                DocumentView(model: model, document: document)
            case .failed(let message):
                FailureView(model: model, message: message)
            }
            Divider()
            StatusBar(model: model, window: window)
        }
        .frame(
            minWidth: Metrics.minWindowWidth,
            minHeight: Metrics.minWindowHeight
        )
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .task { await model.refreshEngines() }
        .sheet(isPresented: $window.showsBrief) {
            BriefEditor(model: model)
        }
        .sheet(isPresented: $window.showsPrivacy) {
            PrivacyPanel(ledger: model.ledger)
        }
        .sheet(isPresented: questionsPresented) {
            ClarificationSheet(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    window.showsBrief = true
                } label: {
                    // The count is on the control because a brief written
                    // last week is applied silently to today's document, and
                    // "3" is the whole warning.
                    Label(
                        model.brief.guidanceLines.isEmpty
                            ? "Brief"
                            : "Brief (\(model.brief.guidanceLines.count))",
                        systemImage: "text.quote"
                    )
                }
                .help("What you want from this translation")
            }
        }
    }

    /// The window says which document it is holding. It is the only place
    /// that can: there is no document browser and no recents list, so a
    /// reader with two Laesesalen windows open has nothing else to tell them
    /// apart by.
    private var title: String {
        model.openDocument?.displayName ?? "Laesesalen"
    }

    private var subtitle: String {
        switch model.phase {
        case .idle: return "简体中文 into English, on this Mac"
        case .working: return model.progress.activity
        case .finished(let document):
            let attention = document.needingAttention.count
            return attention == 0
                ? "Every block passed"
                : "\(attention) need a human eye"
        case .failed: return "Did not finish"
        }
    }

    /// The questions sheet is not something the reader opens — it appears
    /// because the pipeline is parked waiting for an answer, and it closes
    /// when one is given.
    private var questionsPresented: Binding<Bool> {
        Binding(
            get: { !model.questions.isEmpty },
            set: { presented in
                if !presented { model.skipQuestions() }
            }
        )
    }
}

// MARK: - The line along the bottom

/// What is available, and where the receipts are.
///
/// Both of these used to be `.plain` buttons, which on macOS means text that
/// is indistinguishable from a label. The two most reassuring facts the app
/// has — that it is ready, and that nothing has left the machine — were
/// sitting in the corner looking like they could not be pressed.
struct StatusBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 12) {
            StatusBarButton(
                text: engineSummary,
                symbol: model.canTranslate
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill",
                tint: model.canTranslate ? .secondary : .orange,
                help: "Which engines are doing the work"
            ) {
                window.settingsTab = .engines
                openSettings()
            }

            if model.preferences.useLocalServer {
                Chip("model server", symbol: "network")
                    .help("A server on this Mac is in the pipeline")
            }

            Spacer()

            StatusBarButton(
                text: privacySummary,
                symbol: model.ledger.documentsStayedOnThisMac
                    ? "lock.fill"
                    : "lock.trianglebadge.exclamationmark.fill",
                tint: model.ledger.documentsStayedOnThisMac
                    ? .secondary
                    : .red,
                help: "Every connection this app has made"
            ) {
                window.showsPrivacySummary = true
            }
            .popover(
                isPresented: $window.showsPrivacySummary,
                arrowEdge: .top
            ) {
                PrivacySummary(ledger: model.ledger) {
                    window.showsPrivacySummary = false
                    window.showsPrivacy = true
                }
            }
        }
        .padding(.horizontal, Metrics.rowInset)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var engineSummary: String {
        let ready = model.readyEngines.count
        let blocked = model.blockedEngines.count
        if blocked == 0 { return "\(ready) engines ready" }
        return "\(ready) ready, \(blocked) unavailable"
    }

    /// Says what actually happened, not what is promised.
    ///
    /// The wording is careful about a distinction the reader deserves: a
    /// model download is a request to a public host, and the app must not
    /// claim "nothing has left this Mac" once one has been made. What it can
    /// still say — and what the reader is actually asking — is that no
    /// document did.
    private var privacySummary: String {
        let ledger = model.ledger
        guard ledger.totalRequests > 0 else {
            return "Nothing has left this Mac"
        }
        guard ledger.documentsStayedOnThisMac else {
            return "A request went somewhere else — check this"
        }
        let documents = ledger.documentRequests.count
        let downloads = ledger.modelDownloads.count
        if documents == 0 {
            return "No document has left this Mac"
                + (downloads > 0 ? " · \(downloads) model download" : "")
                + (downloads > 1 ? "s" : "")
        }
        return "\(documents) requests, all to this Mac"
    }
}

/// A control that looks like a label until you go near it.
struct StatusBarButton: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary
    let help: String
    let action: () -> Void

    @StateObject private var hover = HoverState()

    final class HoverState: ObservableObject {
        @Published var inside = false
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(text)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .opacity(hover.inside ? 1 : 0)
            }
            .font(.footnote)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(hover.inside ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.inside = $0 }
        .help(help)
    }
}

// MARK: - Failure

/// What the app says when it could not finish.
///
/// The old version of this screen offered one button, "Try another document",
/// which is advice rather than help: the document was rarely the problem. The
/// two things that actually go wrong here are that no engine was ready and
/// that one page defeated the readers, and both have somewhere to go.
struct FailureView: View {
    @ObservedObject var model: AppModel
    let message: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text("The translation stopped")
                .font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Start again") { model.reset() }
                    .keyboardShortcut(.defaultAction)
                if !model.canTranslate {
                    Button("See what is missing") { openSettings() }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
