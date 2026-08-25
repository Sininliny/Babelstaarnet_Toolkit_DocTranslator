import Foundation

/// The one place in the package that opens a connection.
///
/// It is deliberately small and deliberately dull: a POST, a GET, and a
/// line-by-line read for streamed replies, each of them to a
/// `LoopbackEndpoint` and each of them written down in the ledger. Four
/// defaults are set against the grain of `URLSession` because the usual ones
/// are built for the public internet:
///
/// - **Ephemeral configuration.** No cookie jar, no URL cache, no credential
///   store. A translated page must not be recoverable from a cache file after
///   the app quits.
/// - **Proxies off.** A system HTTP proxy is a machine in the middle, and on a
///   managed Mac it may be one the reader has never heard of. Loopback traffic
///   normally bypasses it, but "normally" is a configuration detail; an empty
///   proxy dictionary settles it.
/// - **Redirects refused.** A local server that answered with a 302 to
///   somewhere else would otherwise be followed, and the body of that request
///   is the reader's document.
/// - **No waiting for connectivity.** If nothing is listening, the answer is
///   an error the user can act on, not a request parked until a network
///   appears.
public actor PrivateSession {
    /// Refuses every redirect rather than following it. The delegate is the
    /// only mechanism `URLSession` offers for this, and there is no
    /// configuration flag that replaces it.
    private final class RefusesRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    public enum Failure: LocalizedError {
        case notListening(LoopbackEndpoint)
        case serverError(Int, String)

        public var errorDescription: String? {
            switch self {
            case .notListening(let endpoint):
                return """
                    Nothing is listening on \(endpoint.authority). Start the \
                    local model server and try again.
                    """
            case .serverError(let status, let body):
                let detail = body.prefix(200)
                return "The local model server answered \(status): \(detail)"
            }
        }
    }

    private let session: URLSession
    private let redirects = RefusesRedirects()
    private let ledger: PrivacyLedger

    public init(ledger: PrivacyLedger) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        // A model generating a long answer can be quiet for a while between
        // tokens; a resource timeout measured against a whole page is not a
        // stall.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1_800
        self.session = URLSession(configuration: configuration)
        self.ledger = ledger
    }

    public func get(
        _ endpoint: LoopbackEndpoint,
        path: String
    ) async throws -> Data {
        try await send(
            request(endpoint, path: path, method: "GET", body: nil),
            to: endpoint,
            path: path,
            bytesSent: 0
        )
    }

    public func post(
        _ endpoint: LoopbackEndpoint,
        path: String,
        body: Data
    ) async throws -> Data {
        try await send(
            request(endpoint, path: path, method: "POST", body: body),
            to: endpoint,
            path: path,
            bytesSent: body.count
        )
    }

    /// A streamed reply, one JSON object per line, handed over as it arrives.
    ///
    /// Worth the extra API surface because the alternative is a progress bar
    /// that sits still for a minute per page: the app shows the English
    /// filling in as the model writes it, which is also the only honest
    /// signal that anything is happening.
    public func postLines(
        _ endpoint: LoopbackEndpoint,
        path: String,
        body: Data,
        onLine: @Sendable (String) async -> Void
    ) async throws {
        let request = request(endpoint, path: path, method: "POST", body: body)
        var received = 0
        do {
            let (lines, response) = try await session.bytes(
                for: request,
                delegate: redirects
            )
            try check(response, endpoint: endpoint, path: path)
            for try await line in lines.lines {
                received += line.utf8.count
                await onLine(line)
            }
        } catch {
            await note(
                endpoint,
                path: path,
                outcome: .refused(error.localizedDescription),
                sent: body.count,
                received: received
            )
            throw translate(error, endpoint: endpoint)
        }
        await note(
            endpoint,
            path: path,
            outcome: .allowed,
            sent: body.count,
            received: received
        )
    }

    // MARK: - Plumbing

    private func request(
        _ endpoint: LoopbackEndpoint,
        path: String,
        method: String,
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: endpoint.url(path: path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No user agent beyond the default, no identifiers, and nothing about
        // the document in a header.
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func send(
        _ request: URLRequest,
        to endpoint: LoopbackEndpoint,
        path: String,
        bytesSent: Int
    ) async throws -> Data {
        do {
            let (data, response) = try await session.data(
                for: request,
                delegate: redirects
            )
            try check(response, endpoint: endpoint, path: path, body: data)
            await note(
                endpoint,
                path: path,
                outcome: .allowed,
                sent: bytesSent,
                received: data.count
            )
            return data
        } catch {
            await note(
                endpoint,
                path: path,
                outcome: .refused(error.localizedDescription),
                sent: bytesSent,
                received: 0
            )
            throw translate(error, endpoint: endpoint)
        }
    }

    private func check(
        _ response: URLResponse,
        endpoint: LoopbackEndpoint,
        path: String,
        body: Data = Data()
    ) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.serverError(
                http.statusCode,
                String(decoding: body, as: UTF8.self)
            )
        }
    }

    private func translate(
        _ error: Error,
        endpoint: LoopbackEndpoint
    ) -> Error {
        let code = (error as NSError).code
        if (error as NSError).domain == NSURLErrorDomain,
           code == NSURLErrorCannotConnectToHost
            || code == NSURLErrorNetworkConnectionLost
            || code == NSURLErrorCannotFindHost {
            return Failure.notListening(endpoint)
        }
        return error
    }

    private func note(
        _ endpoint: LoopbackEndpoint,
        path: String,
        outcome: PrivacyLedgerEntry.Outcome,
        sent: Int,
        received: Int
    ) async {
        let entry = PrivacyLedgerEntry(
            authority: endpoint.authority,
            path: path,
            outcome: outcome,
            bytesSent: sent,
            bytesReceived: received
        )
        await ledger.record(entry)
    }
}
