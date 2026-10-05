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
                // Rate limited / temporarily unavailable: the server may say
                // when to come back.
                if http.statusCode == 429 || http.statusCode == 503,
                   let seconds = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")) {
                    return .retryAfter(seconds)
                }
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

/// Longest `Retry-After` the SDK honors. A larger value waits this long, then
/// retries.
let kWhisperrMaxRetryAfter: TimeInterval = 60

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

/// Parses a `Retry-After` value — delay-seconds or an HTTP-date (RFC 9110
/// §10.2.3) — into seconds from `now`, capped at `kWhisperrMaxRetryAfter`.
/// Returns nil when the value is absent or not parseable; the caller then
/// falls back to exponential backoff.
func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        return nil
    }
    let seconds: TimeInterval
    if raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
        guard let parsed = Double(raw) else {
            return nil
        }
        seconds = parsed
    } else if let date = httpDateFormatter.date(from: raw) {
        seconds = max(0, date.timeIntervalSince(now))
    } else {
        return nil
    }
    return min(seconds, kWhisperrMaxRetryAfter)
}
