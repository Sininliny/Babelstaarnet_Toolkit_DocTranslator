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

/// The ledger, which is the app's evidence rather than its promise.
@MainActor
func runLedgerChecks(_ report: Report) {
    report.begin("ledger")

    let ledger = PrivacyLedger()
    report.expect(
        ledger.documentsStayedOnThisMac,
        "an empty ledger has nothing to answer for"
    )

    // A model download is a request to a public host, and the app must not
    // pretend otherwise — but it also must not let that request stand as
    // evidence that a document went anywhere.
    ledger.recordModelDownload(
        host: "huggingface.co",
        model: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        bytesReceived: 2_300_000_000
    )
    report.expect(
        !ledger.stayedOnThisMac,
        "a model download is recorded as having left this Mac"
    )
    report.expect(
        ledger.documentsStayedOnThisMac,
        "but it is not evidence that a document did"
    )
    report.equal(ledger.modelDownloads.count, 1, "it is listed as a download")
    report.equal(
        ledger.documentRequests.count,
        0,
        "and not as document work"
    )

    ledger.record(
        PrivacyLedgerEntry(
            purpose: .documentWork,
            authority: "127.0.0.1:11434",
            path: "/api/chat",
            outcome: .allowed,
            bytesSent: 4_000
        )
    )
    report.expect(
        ledger.documentsStayedOnThisMac,
        "work sent to this machine stayed on this machine"
    )

    // The line that must never appear. If it ever does, the app has to say so
    // rather than average it away.
    ledger.record(
        PrivacyLedgerEntry(
            purpose: .documentWork,
            authority: "example.com:443",
            path: "/v1/chat",
            outcome: .allowed,
            bytesSent: 4_000
        )
    )
    report.expect(
        !ledger.documentsStayedOnThisMac,
        "a document request to anywhere else fails the claim outright"
    )

    // A refused attempt is not a leak: nothing was sent.
    let refused = PrivacyLedger()
    refused.record(
        PrivacyLedgerEntry(
            purpose: .documentWork,
            authority: "example.com:443",
            path: "/v1/chat",
            outcome: .refused("not a loopback address")
        )
    )
    report.expect(
        refused.documentsStayedOnThisMac,
        "a refused request is a request that did not happen"
    )
    report.equal(refused.refusals.count, 1, "and is still written down")
}
