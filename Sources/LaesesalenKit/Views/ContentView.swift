import Combine
import DocCore
import DocIngest
import SwiftUI
import UniformTypeIdentifiers

/// Which sheet is up. A view's own state, held in an object because `@State`
/// is a macro whose plugin ships with Xcode — see `PrivacyLedger` for why
/// this project stays on `ObservableObject` throughout.
final class WindowState: ObservableObject {
    @Published var showsBrief = false
    @Published var showsPrivacy = false
    @Published var showsEngines = false
}

/// The whole window.
///
/// One screen, three states, no navigation. A document translator is a thing
/// you point at a file and read the answer from; anything the reader has to
/// find their way around is in the way.
public struct ContentView: View {
    @StateObject private var model = AppModel()
    @StateObject private var window = WindowState()

    public init() {}

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
                FailureView(message: message) { model.reset() }
            }
            Divider()
            StatusBar(model: model, window: window)
        }
        .frame(minWidth: 760, minHeight: 560)
        .task { await model.refreshEngines() }
        .sheet(isPresented: $window.showsBrief) {
            BriefEditor(model: model)
        }
        .sheet(isPresented: $window.showsPrivacy) {
            PrivacyPanel(ledger: model.ledger)
        }
        .sheet(isPresented: $window.showsEngines) {
            EngineListView(model: model)
        }
        .sheet(isPresented: questionsPresented) {
            ClarificationSheet(model: model)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Translation brief") { window.showsBrief = true }
                    .help("What you want from this translation")
                if model.phase.isWorking {
                    Button("Stop") { model.cancel() }
                }
            }
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

/// The line along the bottom: what is available, and where the receipts are.
struct StatusBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var window: WindowState

    var body: some View {
        HStack(spacing: 12) {
            Button { window.showsEngines = true } label: {
                Label(
                    engineSummary,
                    systemImage: model.canTranslate
                        ? "checkmark.seal"
                        : "exclamationmark.triangle"
                )
            }
            .buttonStyle(.plain)
            .help("Which engines are doing the work")

            Spacer()

            Button { window.showsPrivacy = true } label: {
                Label(privacySummary, systemImage: "lock")
            }
            .buttonStyle(.plain)
            .help("Every connection this app has made")
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try another document", action: retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
