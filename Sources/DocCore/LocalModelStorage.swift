import Foundation

/// A model that is already on this Mac.
public struct InstalledModel: Sendable, Equatable, Identifiable {
    /// The repository identifier, which is also the directory it lives in.
    public let id: String
    public let bytes: Int64
    /// Whether the weights are actually there. A directory with no
    /// `.safetensors` in it is an interrupted download, not a model, and the
    /// difference matters: one is worth keeping and the other is worth
    /// deleting.
    public let isComplete: Bool

    public init(id: String, bytes: Int64, isComplete: Bool) {
        self.id = id
        self.bytes = bytes
        self.isComplete = isComplete
    }

    /// What the catalogue calls it, where the catalogue still knows it.
    public var spec: LocalModelSpec? { LocalModelCatalogue.model(id: id) }

    public var displayName: String { spec?.displayName ?? id }

    /// A model the app no longer offers, left behind by a change to the
    /// catalogue or by a version of the app that is no longer installed.
    /// These are the ones nobody would ever think to look for, so they are
    /// the ones worth naming.
    public var isOrphan: Bool { spec == nil }

    public var size: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Where the weights live, and what is down there.
///
/// Separated from the code that loads models because it is ordinary file
/// handling that happens to be about models, and because the build that most
/// people run has no MLX in it at all — the engine needs Xcode's Metal
/// compiler. That build must still be able to show what a previous build
/// downloaded and to give the disk space back. An app that can install four
/// gigabytes and cannot uninstall them is a bad guest.
///
/// The layout is the Hub's: `<root>/models/<organisation>/<repository>`, so
/// an identifier is exactly two path components and anything else in there is
/// not a model.
public enum LocalModelStorage {

    /// Application Support, rather than the Hub library's default, which is
    /// the reader's Documents folder. A translator that drops four gigabytes
    /// of tensors into someone's Documents has misunderstood whose computer
    /// it is on.
    public static var defaultRoot: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Laesesalen", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static func modelsDirectory(in root: URL) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
    }

    /// Where a given model's files are, or `nil` for an identifier that is
    /// not one.
    ///
    /// The validation is not decoration. This is the path a deletion is
    /// performed on, the identifier reaching it came out of a preferences
    /// file, and `../../..` names somebody's home folder. So an identifier is
    /// two non-empty components, neither of which may be a relative path.
    public static func directory(for id: String, in root: URL) -> URL? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return modelsDirectory(in: root)
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
    }

    /// Whether the weights are already here.
    ///
    /// Checked by looking for a weights file rather than for the directory,
    /// because "the folder exists" is also true of a download that was
    /// interrupted half way — and treating that as a model on disk turns the
    /// app's first page into a silent two-gigabyte download.
    public static func isOnDisk(_ id: String, in root: URL) -> Bool {
        guard let directory = directory(for: id, in: root) else { return false }
        return hasWeights(directory)
    }

    static func hasWeights(_ directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ) else { return false }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Everything under the models directory, whether the catalogue still
    /// knows about it or not.
    public static func installed(in root: URL) -> [InstalledModel] {
        let manager = FileManager.default
        let models = modelsDirectory(in: root)
        guard let organisations = try? manager.contentsOfDirectory(
            at: models,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var found: [InstalledModel] = []
        for organisation in organisations where isDirectory(organisation) {
            guard let repositories = try? manager.contentsOfDirectory(
                at: organisation,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for repository in repositories where isDirectory(repository) {
                found.append(
                    InstalledModel(
                        id: organisation.lastPathComponent + "/"
                            + repository.lastPathComponent,
                        bytes: bytes(of: repository),
                        isComplete: hasWeights(repository)
                    )
                )
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    /// What is on disk that nothing is going to use.
    ///
    /// The two kinds it finds are different and both worth removing: a model
    /// the reader tried and moved on from, and one this version of the app no
    /// longer offers at all. The second kind is invisible from every other
    /// screen — the catalogue does not list it, so nothing would ever mention
    /// the four gigabytes again.
    public static func unused(
        keeping inUse: Set<String>,
        in root: URL
    ) -> [InstalledModel] {
        installed(in: root).filter { !inUse.contains($0.id) }
    }

    public static func totalBytes(in root: URL) -> Int64 {
        installed(in: root).reduce(0) { $0 + $1.bytes }
    }

    /// Delete one model's weights.
    ///
    /// Refuses anything that is not a model identifier, and refuses to touch
    /// a path that is not inside the models directory — the identifier came
    /// from a stored preference, and a deletion is the one operation here
    /// that cannot be taken back.
    @discardableResult
    public static func remove(_ id: String, in root: URL) throws -> Int64 {
        guard let directory = directory(for: id, in: root) else {
            throw StorageFailure.notAModelIdentifier(id)
        }
        let models = modelsDirectory(in: root).standardizedFileURL.path
        guard directory.standardizedFileURL.path.hasPrefix(models) else {
            throw StorageFailure.notAModelIdentifier(id)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return 0
        }
        let size = bytes(of: directory)
        try FileManager.default.removeItem(at: directory)
        // An organisation directory with nothing left in it is not evidence
        // of anything.
        let organisation = directory.deletingLastPathComponent()
        if let rest = try? FileManager.default.contentsOfDirectory(
            atPath: organisation.path
        ), rest.isEmpty {
            try? FileManager.default.removeItem(at: organisation)
        }
        return size
    }

    public enum StorageFailure: LocalizedError, Equatable {
        case notAModelIdentifier(String)

        public var errorDescription: String? {
            switch self {
            case .notAModelIdentifier(let id):
                return "“\(id)” is not a model this app installed."
            }
        }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            ?? false
    }

    static func bytes(of directory: URL) -> Int64 {
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
}
