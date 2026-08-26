#if MLXEngine

import DocCore
import Foundation
import Hub
import MLXLMCommon

/// How far along a model's arrival is.
public enum MLXModelState: Sendable, Equatable {
    case notFetched
    case fetching(fraction: Double)
    /// On disk, but not yet in memory.
    case onDisk
    case loading
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }

    public var isBusy: Bool {
        switch self {
        case .fetching, .loading: return true
        default: return false
        }
    }
}

/// A single network event, reported so the app can write it down.
///
/// This target does not know about the privacy ledger and does not import it.
/// It reports; the app records. That keeps the one place in this project that
/// reaches the internet from also being the place that decides how honestly
/// to describe it.
public struct MLXFetchReport: Sendable {
    public let model: String
    public let host: String
    public let fraction: Double
    public let bytesReceived: Int64
    public let finished: Bool
}

/// One of the app's own models: fetched once, then held in memory and run on
/// this machine's GPU.
///
/// The weights come from Hugging Face the first time and from the disk every
/// time after. That download is the only moment this app talks to the
/// internet, it happens because someone pressed a button, and no part of any
/// document is involved in it — the request is for a file by name. Everything
/// the model is then asked about stays in this process.
///
/// A store holds one model. The app has one for the page reader and, on a Mac
/// with room for both, a second for the text work — which is why the model it
/// holds is a value it is given rather than a constant it knows.
public actor MLXModelStore {
    public private(set) var state: MLXModelState = .notFetched
    public private(set) var model: LocalModelSpec

    private var container: ModelContainer?
    private let hub: HubApi
    private let root: URL
    /// Reports the state *and* which model it belongs to. Both, because a
    /// store can be told to hold a different model: a callback that closed
    /// over the model it was built with would announce a 7B download under
    /// the name of the 3B the reader switched away from.
    private let onEvent: @Sendable (MLXModelState, LocalModelSpec) -> Void
    private let onFetch: @Sendable (MLXFetchReport) -> Void

    public init(
        model: LocalModelSpec = LocalModelCatalogue.fallback,
        root: URL? = nil,
        onEvent: @escaping @Sendable (MLXModelState, LocalModelSpec) -> Void
            = { _, _ in },
        onFetch: @escaping @Sendable (MLXFetchReport) -> Void = { _ in }
    ) {
        self.model = model
        let base = root ?? LocalModelStorage.defaultRoot
        self.root = base
        self.hub = HubApi(downloadBase: base)
        self.onEvent = onEvent
        self.onFetch = onFetch
        self.state = LocalModelStorage.isOnDisk(model.id, in: base)
            ? .onDisk
            : .notFetched
    }

    /// Where the weights are put: Application Support, rather than the Hub
    /// library's default, which is the reader's Documents folder.
    public static var defaultRoot: URL { LocalModelStorage.defaultRoot }

    public static func isOnDisk(_ model: LocalModelSpec, root: URL) -> Bool {
        LocalModelStorage.isOnDisk(model.id, in: root)
    }

    public func use(_ model: LocalModelSpec) {
        guard model != self.model else { return }
        container = nil
        self.model = model
        set(
            LocalModelStorage.isOnDisk(model.id, in: root)
                ? .onDisk
                : .notFetched
        )
    }

    public func currentState() -> MLXModelState { state }

    /// Whether this model could do a job right now: on the disk, or already
    /// in memory. A model that is still downloading is not a reader — quietly
    /// waiting for a multi-gigabyte download in the middle of someone's first
    /// page looks exactly like the app having hung.
    public var isUsable: Bool {
        state == .onDisk || state == .ready
    }

    /// Fetch if needed, then load. Safe to call repeatedly: the second call
    /// gets the container the first one built.
    @discardableResult
    public func prepare() async throws -> ModelContainer {
        if let container, state == .ready { return container }

        let wasOnDisk = LocalModelStorage.isOnDisk(model.id, in: root)
        // Checked before the download rather than during it. A fetch that
        // fills the disk and then fails has left the reader worse off than
        // when they pressed the button, and the failure it produces names a
        // temporary file rather than the problem.
        if !wasOnDisk {
            let machine = MachineCapability.thisMac(diskAt: root)
            guard machine.hasRoomOnDisk(for: model.approximateBytes) else {
                let problem = MLXModelFailure.noRoomOnDisk(
                    needs: model.approximateSize,
                    free: machine.freeDiskDescription
                )
                set(.failed(problem.localizedDescription))
                throw problem
            }
        }
        set(wasOnDisk ? .loading : .fetching(fraction: 0))

        let model = self.model
        let onFetch = self.onFetch
        let report = self.reporter()

        do {
            let loaded = try await MLXModelCatalogue.loadContainer(
                model,
                hub: hub
            ) { progress in
                report(progress.fractionCompleted)
                onFetch(
                    MLXFetchReport(
                        model: model.id,
                        host: "huggingface.co",
                        fraction: progress.fractionCompleted,
                        bytesReceived: progress.completedUnitCount,
                        finished: progress.fractionCompleted >= 1
                    )
                )
            }
            if !wasOnDisk {
                onFetch(
                    MLXFetchReport(
                        model: model.id,
                        host: "huggingface.co",
                        fraction: 1,
                        bytesReceived: bytesOnDisk(),
                        finished: true
                    )
                )
            }
            // The reader may have chosen a different model while this was
            // downloading — `use` is served between the awaits above, and it
            // is the one thing that can change what this store holds. The
            // container that has just arrived is the old model's; adopting it
            // would report the newly chosen model as ready and then read
            // pages with the one it replaced.
            guard model == self.model else { return loaded }
            container = loaded
            set(.ready)
            return loaded
        } catch {
            guard model == self.model else { throw error }
            set(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Give the memory back. A model is several gigabytes of resident
    /// weights, and an app that keeps them after the reader has finished a
    /// document is an app that gets quit rather than left open.
    public func unload() {
        container = nil
        set(
            LocalModelStorage.isOnDisk(model.id, in: root)
                ? .onDisk
                : .notFetched
        )
    }

    /// Everything this store fetched, removed.
    public func removeFromDisk() throws {
        container = nil
        try LocalModelStorage.remove(model.id, in: root)
        set(.notFetched)
    }

    /// Remove some other model — one the reader tried and moved on from, or
    /// one a previous version of the app downloaded and this one no longer
    /// offers.
    ///
    /// Goes through the store rather than around it because the model being
    /// deleted may be the one this store is holding in memory, and deleting
    /// the weights out from under a loaded container leaves the app in a
    /// state where everything works until the next launch.
    @discardableResult
    public func remove(id: String) throws -> Int64 {
        if id == model.id { container = nil }
        let freed = try LocalModelStorage.remove(id, in: root)
        if id == model.id { set(.notFetched) }
        return freed
    }

    public func installed() -> [InstalledModel] {
        LocalModelStorage.installed(in: root)
    }

    public func bytesOnDisk() -> Int64 {
        LocalModelStorage.totalBytes(in: root)
    }

    public enum MLXModelFailure: LocalizedError, Equatable {
        case noRoomOnDisk(needs: String, free: String)

        public var errorDescription: String? {
            switch self {
            case .noRoomOnDisk(let needs, let free):
                return "This model needs about \(needs) and there is \(free) "
                    + "free. Remove a model you are not using, or choose a "
                    + "smaller one."
            }
        }
    }

    private func set(_ state: MLXModelState) {
        self.state = state
        onEvent(state, model)
    }

    /// Progress arrives on whatever thread the Hub is downloading on, so the
    /// hop back into the actor is explicit.
    private nonisolated func reporter() -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { [weak self] in
                await self?.observed(fraction: fraction)
            }
        }
    }

    private func observed(fraction: Double) {
        guard case .fetching = state else { return }
        set(fraction >= 1 ? .loading : .fetching(fraction: fraction))
    }
}

#endif
