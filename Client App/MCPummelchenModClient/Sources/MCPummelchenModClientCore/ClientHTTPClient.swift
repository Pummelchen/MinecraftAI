import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCPummelchenModShared

public actor ClientHTTPProtocolRecorder {
    private var lastProtocol: String?

    public init() {}

    public func record(_ value: String?) {
        guard let value, !value.isEmpty else {
            return
        }
        lastProtocol = value
    }

    public func latest() -> String? {
        lastProtocol
    }
}

public enum PummelchenNetworkDefaults {
    public static let primaryServerURL = URL(string: "https://pummelchen.91.99.176.243.nip.io")!
    public static let ipv6ServerURL = URL(string: "https://pummelchen.2a01-4f8-c17-ecab--1.nip.io")!

    public static let fallbackHosts: [String: [String]] = [
        "pummelchen.91.99.176.243.nip.io": ["pummelchen.2a01-4f8-c17-ecab--1.nip.io"]
    ]
}

#if os(macOS)
private final class ClientHTTPMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let recorder: ClientHTTPProtocolRecorder

    init(recorder: ClientHTTPProtocolRecorder) {
        self.recorder = recorder
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let protocolName = metrics.transactionMetrics
            .reversed()
            .compactMap(\.networkProtocolName)
            .first
        Task {
            await recorder.record(protocolName)
        }
    }
}
#endif

public struct ClientHTTPRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let requestTimeoutSeconds: TimeInterval
    public let baseDelayNanoseconds: UInt64

    public init(
        maxAttempts: Int = 4,
        requestTimeoutSeconds: TimeInterval = 300,
        baseDelayNanoseconds: UInt64 = 700_000_000
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.baseDelayNanoseconds = baseDelayNanoseconds
    }
}

public enum ClientHTTPError: Error, CustomStringConvertible {
    case httpStatus(Int, URL)
    case emptyDownload(URL)

    public var description: String {
        switch self {
        case .httpStatus(let status, let url):
            return "HTTP \(status) for \(url.absoluteString)"
        case .emptyDownload(let url):
            return "empty download from \(url.absoluteString)"
        }
    }
}

public struct ClientHTTPClient: Sendable {
    public let retryPolicy: ClientHTTPRetryPolicy
    private let session: URLSession
    private let protocolRecorder: ClientHTTPProtocolRecorder
    private let fallbackHosts: [String: [String]]
    #if os(macOS)
    private let metricsDelegate: ClientHTTPMetricsDelegate
    #endif

    public init(
        retryPolicy: ClientHTTPRetryPolicy = ClientHTTPRetryPolicy(),
        fallbackHosts: [String: [String]] = PummelchenNetworkDefaults.fallbackHosts
    ) {
        self.retryPolicy = retryPolicy
        self.protocolRecorder = ClientHTTPProtocolRecorder()
        self.fallbackHosts = fallbackHosts
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = retryPolicy.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = max(retryPolicy.requestTimeoutSeconds, 900)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if os(macOS)
        let metricsDelegate = ClientHTTPMetricsDelegate(recorder: protocolRecorder)
        self.metricsDelegate = metricsDelegate
        self.session = URLSession(configuration: configuration, delegate: metricsDelegate, delegateQueue: nil)
        #else
        self.session = URLSession(configuration: configuration)
        #endif
    }

    public func lastNegotiatedProtocol() async -> String? {
        await protocolRecorder.latest()
    }

    public func data(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        try await retryingCandidates(for: url) { candidateURL in
            var request = Self.request(url: candidateURL, timeout: retryPolicy.requestTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await session.data(for: request)
            try Self.requireSuccess(response: response, url: candidateURL)
            return data
        }
    }

    public func download(from url: URL, headers: [String: String] = [:]) async throws -> URL {
        try await retryingCandidates(for: url) { candidateURL in
            var request = Self.request(url: candidateURL, timeout: retryPolicy.requestTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (file, response) = try await session.download(for: request)
            try Self.requireSuccess(response: response, url: candidateURL)
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                throw ClientHTTPError.emptyDownload(candidateURL)
            }
            return file
        }
    }

    public func send(_ request: URLRequest) async throws -> Data {
        try await retryingCandidates(for: request.url ?? URL(fileURLWithPath: "/")) { candidateURL in
            var next = request
            next.url = candidateURL
            next.timeoutInterval = retryPolicy.requestTimeoutSeconds
            Self.configureTransportPreferences(&next)
            let (data, response) = try await session.data(for: next)
            try Self.requireSuccess(response: response, url: next.url ?? URL(fileURLWithPath: "/"))
            return data
        }
    }

    static func request(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        configureTransportPreferences(&request)
        return request
    }

    static func configureTransportPreferences(_ request: inout URLRequest) {
        #if os(macOS)
        request.assumesHTTP3Capable = true
        #endif
    }

    public func fallbackCandidateURLs(for url: URL) -> [URL] {
        Self.fallbackCandidateURLs(for: url, fallbackHosts: fallbackHosts)
    }

    public static func fallbackCandidateURLs(for url: URL, fallbackHosts: [String: [String]] = PummelchenNetworkDefaults.fallbackHosts) -> [URL] {
        guard let host = url.host(percentEncoded: false), let fallbackHostnames = fallbackHosts[host], !fallbackHostnames.isEmpty else {
            return [url]
        }
        var candidates = [url]
        for fallbackHost in fallbackHostnames where fallbackHost != host {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                continue
            }
            components.host = fallbackHost
            if let fallbackURL = components.url, !candidates.contains(fallbackURL) {
                candidates.append(fallbackURL)
            }
        }
        return candidates
    }

    private func retryingCandidates<T: Sendable>(
        for url: URL,
        _ operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        let candidates = fallbackCandidateURLs(for: url)
        for attempt in 1...retryPolicy.maxAttempts {
            for candidate in candidates {
                do {
                    return try await operation(candidate)
                } catch {
                    lastError = error
                    if !Self.isRetryable(error) {
                        throw error
                    }
                }
            }
            if attempt < retryPolicy.maxAttempts {
                let multiplier = UInt64(1 << min(attempt - 1, 4))
                try await Task.sleep(nanoseconds: retryPolicy.baseDelayNanoseconds * multiplier)
            }
        }
        throw lastError ?? ContractValidationError.invalid("HTTP request failed without an error")
    }

    private static func requireSuccess(response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientHTTPError.httpStatus(http.statusCode, url)
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case ClientHTTPError.httpStatus(let status, _) = error {
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff,
                NSURLErrorCallIsActive,
                NSURLErrorDataNotAllowed,
                NSURLErrorSecureConnectionFailed
            ].contains(ns.code)
        }
        return false
    }
}
