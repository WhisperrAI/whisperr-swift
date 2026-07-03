import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol WhisperrTransport: Sendable {
    func send(path: String, body: JSONValue) async -> WhisperrSendResult
}

public final class URLSessionWhisperrTransport: WhisperrTransport, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let sdkVersion: String
    private let timeout: TimeInterval
    private let session: URLSession

    public init(
        baseURL: URL,
        apiKey: String,
        sdkVersion: String = kWhisperrSdkVersion,
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sdkVersion = sdkVersion
        self.timeout = timeout
        self.session = session
    }

    public func send(path: String, body: JSONValue) async -> WhisperrSendResult {
        do {
            var request = URLRequest(url: endpoint(path))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("swift/\(sdkVersion)", forHTTPHeaderField: "X-Whisperr-Sdk")
            request.httpBody = try JSONEncoder.whisperr.encode(body)

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .retry
            }
            if (200..<300).contains(http.statusCode) {
                return .ok
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .auth(http.statusCode)
            }
            if http.statusCode == 429 || http.statusCode >= 500 {
                return .retry
            }
            return .drop(http.statusCode)
        } catch {
            return .retry
        }
    }

    private func endpoint(_ path: String) -> URL {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(cleanPath)
    }
}
