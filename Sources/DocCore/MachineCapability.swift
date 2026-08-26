import Foundation

/// What this Mac can actually run, measured rather than assumed.
///
/// The app carries its own vision-language model, and the only honest way to
/// decide how large that model should be is to ask the machine. A default
/// chosen once for everybody is wrong in both directions: it wastes a Mac
/// with sixty-four gigabytes, which could be reading pages with a model four
/// times the size, and it wedges an eight-gigabyte one, where a model that
/// does not fit does not fail cleanly — the machine swaps, the fans start,
/// and a page that should take twenty seconds takes four minutes.
///
/// Everything here is read from the machine itself. Nothing is asked of a
/// network, and nothing is remembered between launches: a Mac gains and loses
/// free disk between one document and the next.
public struct MachineCapability: Sendable, Equatable {
    /// Whether MLX can run here at all. MLX is Metal on Apple silicon; on an
    /// Intel Mac there is no local model, and saying so plainly is better
    /// than offering a download that will never load.
    public let isAppleSilicon: Bool
    /// "Apple M4 Pro", as the machine describes itself.
    public let chip: String
    /// Unified memory. On Apple silicon this is the GPU's memory too, which
    /// is the whole reason a laptop can hold a several-billion-parameter
    /// model at all.
    public let memoryBytes: Int64
    public let cores: Int
    /// Free space where the weights would go, at the moment of asking.
    public let freeDiskBytes: Int64

    public init(
        isAppleSilicon: Bool,
        chip: String,
        memoryBytes: Int64,
        cores: Int,
        freeDiskBytes: Int64
    ) {
        self.isAppleSilicon = isAppleSilicon
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.cores = cores
        self.freeDiskBytes = freeDiskBytes
    }

    /// How much of the machine a model may take.
    ///
    /// Three quarters, and the number is not arbitrary: macOS caps what a
    /// process may wire for the GPU at around that share of unified memory,
    /// so a model whose working set is larger does not run slowly — it fails
    /// to allocate, or it thrashes. The remaining quarter is also where the
    /// window, the page images, the PDF being rendered, and everything else
    /// the reader has open live. A translator that takes the whole machine is
    /// one that gets force-quit.
    public var usableMemoryBytes: Int64 { memoryBytes * 3 / 4 }

    /// Whether a model of this working set is one this Mac should be asked to
    /// hold.
    public func canHold(workingSet bytes: Int64) -> Bool {
        isAppleSilicon && bytes <= usableMemoryBytes
    }

    /// Whether the weights would fit on the disk, with a gigabyte left over.
    ///
    /// The gigabyte is for the download itself: the Hub writes the file and
    /// then moves it, so a disk with exactly enough room is a disk with not
    /// quite enough.
    public func hasRoomOnDisk(for bytes: Int64) -> Bool {
        freeDiskBytes >= bytes + 1_000_000_000
    }

    public var memoryDescription: String {
        ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
    }

    public var freeDiskDescription: String {
        ByteCountFormatter.string(fromByteCount: freeDiskBytes, countStyle: .file)
    }

    /// One line for the interface: what the app can see about this Mac, so a
    /// recommendation is something the reader can check rather than take.
    public var summary: String {
        guard isAppleSilicon else {
            return "\(chip) — no Apple-silicon GPU, so the app's own model "
                + "cannot run here"
        }
        return "\(chip) · \(memoryDescription) memory · "
            + "\(freeDiskDescription) free"
    }

    // MARK: - Asking the machine

    /// - Parameter diskAt: where the weights would be written. Free space is
    ///   a property of a volume, not of a computer, and the models do not
    ///   necessarily live on the startup disk.
    public static func thisMac(diskAt location: URL? = nil) -> MachineCapability {
        let info = ProcessInfo.processInfo
        return MachineCapability(
            isAppleSilicon: sysctlFlag("hw.optional.arm64"),
            chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown Mac",
            memoryBytes: Int64(info.physicalMemory),
            cores: info.activeProcessorCount,
            freeDiskBytes: freeBytes(at: location ?? defaultLocation)
        )
    }

    private static var defaultLocation: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Free space in the sense the reader means it — including what the
    /// system would purge to make room, which is what the Finder shows and
    /// what a download can actually use.
    public static func freeBytes(at location: URL) -> Int64 {
        var url = location
        // The directory may not exist yet on a first run; the volume it would
        // be on does.
        while !FileManager.default.fileExists(atPath: url.path),
              url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }
}
