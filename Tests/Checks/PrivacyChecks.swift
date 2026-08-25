import DocPrivacy
import Foundation

/// The privacy guarantee, checked as a property of the types.
func runPrivacyChecks(_ report: Report) {
    report.begin("loopback")

    let allowed = ["127.0.0.1", "127.1.2.3", "localhost", "LOCALHOST", "::1"]
    for host in allowed {
        report.expect(
            (try? LoopbackEndpoint(host: host, port: 11_434)) != nil,
            "\(host) should be accepted"
        )
    }

    // The addresses that matter: a public host, a private-network host, one
    // that merely begins with 127, and a name someone else controls that
    // starts with a loopback literal.
    let refused = [
        "example.com",
        "1.1.1.1",
        "192.168.1.10",
        "10.0.0.1",
        "127.0.0.1.example.com",
        "localhost.evil.com",
        "0.0.0.0",
        "fe80::1"
    ]
    for host in refused {
        report.expect(
            (try? LoopbackEndpoint(host: host, port: 11_434)) == nil,
            "\(host) must be refused"
        )
    }

    // A name is never resolved: localhost becomes the literal, so a hosts
    // file cannot move it.
    let local = try? LoopbackEndpoint(host: "localhost", port: 8_080)
    report.equal(local?.host, "127.0.0.1", "localhost is normalized")
    report.equal(
        local?.url(path: "api/chat").absoluteString,
        "http://127.0.0.1:8080/api/chat",
        "a path without a slash still forms a loopback URL"
    )

    let v6 = try? LoopbackEndpoint(host: "::1", port: 8_080)
    report.equal(
        v6?.authority,
        "[::1]:8080",
        "IPv6 literals are bracketed in a URL"
    )

    for port in [0, -1, 65_536] {
        report.expect(
            (try? LoopbackEndpoint(host: "127.0.0.1", port: port)) == nil,
            "port \(port) must be refused"
        )
    }
}
