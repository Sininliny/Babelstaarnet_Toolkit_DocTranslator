import Foundation

/// An address on this machine, and the only kind of address the app can form.
///
/// The privacy guarantee is meant to survive a careless edit, so it is stated
/// as a type rather than as a rule someone has to remember. `PrivateSession`
/// accepts nothing but a `LoopbackEndpoint`, this initializer accepts nothing
/// but a loopback address, and no target outside `DocPrivacy` links a
/// networking API at all — so a page could only be sent somewhere else by
/// editing `Package.swift` first.
///
/// `localhost` is normalized to `127.0.0.1` rather than resolved. Resolution
/// reads `/etc/hosts` and the DNS configuration, and neither is under this
/// app's control; a name that resolves somewhere else today would be a
/// loopback address for as long as anyone looked at the code.
public struct LoopbackEndpoint: Hashable, Sendable, CustomStringConvertible {
    public enum Rejection: LocalizedError, Equatable {
        case notLoopback(String)
        case malformedAddress(String)
        case portOutOfRange(Int)

        public var errorDescription: String? {
            switch self {
            case .notLoopback(let host):
                return """
                    \(host) is not this machine. Laesesalen only ever connects \
                    to 127.0.0.1.
                    """
            case .malformedAddress(let host):
                return "\(host) is not an address."
            case .portOutOfRange(let port):
                return "\(port) is not a port number."
            }
        }
    }

    /// Always a literal address — `127.0.0.1` or `::1` — never a name.
    public let host: String
    public let port: Int
    /// Whether the literal needs bracketing in a URL, which IPv6 does.
    private let isIPv6: Bool

    public init(host: String, port: Int) throws {
        guard (1...65_535).contains(port) else {
            throw Rejection.portOutOfRange(port)
        }
        let trimmed = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if trimmed == "localhost" {
            self.host = "127.0.0.1"
            self.isIPv6 = false
            self.port = port
            return
        }

        switch Self.classify(trimmed) {
        case .loopbackV4:
            self.host = trimmed
            self.isIPv6 = false
        case .loopbackV6:
            self.host = trimmed
            self.isIPv6 = true
        case .routable:
            throw Rejection.notLoopback(trimmed)
        case .notAnAddress:
            throw Rejection.malformedAddress(trimmed)
        }
        self.port = port
    }

    /// The address Ollama listens on out of the box.
    public static let ollama = try! LoopbackEndpoint(
        host: "127.0.0.1",
        port: 11_434
    )

    /// A llama.cpp server started with `--host 127.0.0.1`.
    public static let llamaServer = try! LoopbackEndpoint(
        host: "127.0.0.1",
        port: 8_080
    )

    public var description: String { authority }

    /// `127.0.0.1:11434`, or `[::1]:11434` for IPv6.
    public var authority: String {
        isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Built from the literal every time rather than stored, so there is no
    /// way to hold a `LoopbackEndpoint` whose URL points somewhere else.
    public func url(path: String) -> URL {
        let suffix = path.hasPrefix("/") ? path : "/" + path
        // Loopback literals and a caller-supplied path make a URL that cannot
        // fail to parse; the force is over a string this type controls.
        return URL(string: "http://\(authority)\(suffix)")!
    }

    // MARK: - Address classification

    private enum Classification {
        case loopbackV4
        case loopbackV6
        case routable
        case notAnAddress
    }

    /// Decided by the C resolver's parser, not by string prefixes. `127.1` and
    /// `0177.0.0.1` are both loopback and neither begins with `127.0`, while
    /// `127.0.0.1.example.com` begins with `127.0` and is a name someone else
    /// controls.
    private static func classify(_ address: String) -> Classification {
        var v4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            // The whole 127.0.0.0/8 block, which is what the stack treats as
            // this machine.
            let host = UInt32(bigEndian: v4.s_addr)
            return (host >> 24) == 127 ? .loopbackV4 : .routable
        }

        var v6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            var loopback = in6addr_loopback
            let isLoopback = withUnsafeBytes(of: &v6) { lhs in
                withUnsafeBytes(of: &loopback) { rhs in
                    lhs.elementsEqual(rhs)
                }
            }
            return isLoopback ? .loopbackV6 : .routable
        }

        return .notAnAddress
    }
}
