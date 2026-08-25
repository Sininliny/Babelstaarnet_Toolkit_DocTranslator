import Combine
import Foundation

/// One connection the app opened, or refused to open.
public struct PrivacyLedgerEntry: Identifiable, Sendable {
    public enum Outcome: Sendable, Equatable {
        case allowed
        case refused(String)

        public var wasRefused: Bool {
            if case .refused = self { return true }
            return false
        }
    }

    public let id = UUID()
    public let at: Date
    public let authority: String
    public let path: String
    public let outcome: Outcome
    public let bytesSent: Int
    public let bytesReceived: Int

    public init(
        at: Date = Date(),
        authority: String,
        path: String,
        outcome: Outcome,
        bytesSent: Int = 0,
        bytesReceived: Int = 0
    ) {
        self.at = at
        self.authority = authority
        self.path = path
        self.outcome = outcome
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
    }
}

/// Every connection the app has made this session, in a form a reader can
/// check for themselves.
///
/// The claim on the box is that a document never leaves the Mac. A user has no
/// way to verify that from the outside, and "trust us" is exactly what a
/// privacy claim cannot be built on, so the app keeps the receipts and shows
/// them: every request, its address, and how many bytes went each way. If a
/// line ever appears here whose address is not this machine, the claim is
/// broken and the evidence is in the window rather than in a packet capture
/// nobody is going to run.
///
/// Built on `ObservableObject` rather than the newer `@Observable`, and so is
/// everything else in this app that a view watches. `@State` is a macro in
/// the current SDK, and its plugin ships with Xcode rather than with the
/// Command Line Tools — so a project that reaches for it cannot be built from
/// a plain checkout on a machine that has only the tools. The older pair
/// costs a few more lines and builds anywhere.
@MainActor
public final class PrivacyLedger: ObservableObject {
    @Published public private(set) var entries: [PrivacyLedgerEntry] = []
    /// Bounded because a long document is thousands of model calls, and a
    /// receipt list nobody can scroll is not evidence of anything.
    private let capacity: Int
    /// Kept separately so the totals stay true after old lines are dropped.
    @Published public private(set) var totalRequests = 0
    @Published public private(set) var totalBytesSent = 0
    @Published public private(set) var totalBytesReceived = 0
    @Published public private(set) var addressesContacted: Set<String> = []

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func record(_ entry: PrivacyLedgerEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        totalRequests += 1
        totalBytesSent += entry.bytesSent
        totalBytesReceived += entry.bytesReceived
        if case .allowed = entry.outcome {
            addressesContacted.insert(entry.authority)
        }
    }

    public func clear() {
        entries.removeAll()
        totalRequests = 0
        totalBytesSent = 0
        totalBytesReceived = 0
        addressesContacted.removeAll()
    }

    /// True when nothing but this machine was ever contacted, which is the
    /// only state the app is designed to be able to reach.
    public var stayedOnThisMac: Bool {
        addressesContacted.allSatisfy { authority in
            authority.hasPrefix("127.") || authority.hasPrefix("[::1]")
        }
    }

    public var refusals: [PrivacyLedgerEntry] {
        entries.filter(\.outcome.wasRefused)
    }
}
