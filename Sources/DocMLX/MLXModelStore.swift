#if MLXEngine

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
    public let finished: Bool
}

/// The app's own model: fetched once, then held in memory and run on this
/// machine's GPU.
///
/// The weights come from Hugging Face the first time and from the disk every
/// time after. That download is the only moment this app talks to the
/// internet, it happens because someone pressed a button, and no part of any
/// document is involved in it — the request is for a file by name. Everything
/// the model is then asked about stays in this process.
///
/// Weights are put in Application Support rather than the Hub library's
/// default, which is the user's Documents folder. A translator that drops two
/// gigabytes of tensors into someone's Documents has misunderstood whose
/// computer it is on.
public actor MLXModelStore {
    public private(set) var state: MLXModelState = .notFetched
    public private(set) var model: MLXModel

    private var container: ModelContainer?
    private let hub: HubApi
    private let root: URL
    private let onEvent: @Sendable (MLXModelState) -> Void
    private let onFetch: @Sendable (MLXFetchReport) -> Void

    public init(
        model: MLXModel = MLXModelCatalogue.default,
        root: URL? = nil,
        onEvent: @escaping @Sendable (MLXModelState) -> Void = { _ in },
        onFetch: @escaping @Sendable (MLXFetchReport) -> Void = { _ in }
    ) {
        self.model = model
        let base = root ?? Self.defaultRoot
        self.root = base
        self.hub = HubApi(downloadBase: base)
        self.onEvent = onEvent
        self.onFetch = onFetch
        self.state = Self.isOnDisk(model, root: base) ? .onDisk : .notFetched
    }

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Laesesalen", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Whether the weights are already here. Checked by looking for the
    /// repository directory with a weights file in it, because "the folder
    /// exists" is also true of a download that was interrupted.
    public static func isOnDisk(_ model: MLXModel, root: URL) -> Bool {
        let directory = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else { return false }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    public func use(_ model: MLXModel) {
        guard model != self.model else { return }
        container = nil
        self.model = model
        set(Self.isOnDisk(model, root: root) ? .onDisk : .notFetched)
    }

    public func currentState() -> MLXModelState { state }

    /// Fetch if needed, then load. Safe to call repeatedly: the second call
    /// gets the container the first one built.
    @discardableResult
    public func prepare() async throws -> ModelContainer {
        if let container, state == .ready { return container }

        let wasOnDisk = Self.isOnDisk(model, root: root)
        set(wasOnDisk ? .loading : .fetching(fraction: 0))

        let model = self.model
        let onFetch = self.onFetch
        let report = self.reporter()

        do {
            let loaded = try await loadModelContainer(
                hub: hub,
                configuration: model.configuration
            ) { progress in
                report(progress.fractionCompleted)
                onFetch(
                    MLXFetchReport(
                        model: model.id,
                        host: "huggingface.co",
                        fraction: progress.fractionCompleted,
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
                        finished: true
                    )
                )
            }
            container = loaded
            set(.ready)
            return loaded
        } catch {
            set(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Give the memory back. A 3B model is a couple of gigabytes of resident
    /// weights, and an app that keeps them after the reader has finished a
    /// document is an app that gets quit rather than left open.
    public func unload() {
        container = nil
        set(Self.isOnDisk(model, root: root) ? .onDisk : .notFetched)
    }

    /// Everything fetched, removed. Offered because a model the reader is
    /// finished with is two gigabytes they may want back, and an app that
    /// cannot uninstall what it installed is a bad guest.
    public func removeFromDisk() throws {
        container = nil
        let directory = root
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        set(.notFetched)
    }

    public func bytesOnDisk() -> Int64 {
        let directory = root.appendingPathComponent("models", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    private func set(_ state: MLXModelState) {
        self.state = state
        onEvent(state)
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
