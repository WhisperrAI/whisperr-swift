import Foundation
@testable import Whisperr

actor MockTransport: WhisperrTransport {
    struct Request: Equatable {
        let path: String
        let body: JSONValue
    }

    private var result: WhisperrSendResult
    private(set) var requests: [Request] = []

    init(result: WhisperrSendResult = .ok) {
        self.result = result
    }

    func setResult(_ result: WhisperrSendResult) {
        self.result = result
    }

    func send(path: String, body: JSONValue) async -> WhisperrSendResult {
        requests.append(Request(path: path, body: body))
        return result
    }

    func batchBodies() -> [JSONValue] {
        requests.filter { $0.path == "/v1/events/batch" }.map(\.body)
    }
}

func makeClient(
    transport: MockTransport,
    maxRetries: Int = 2,
    persistence: WhisperrPersistence? = nil,
    clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_780_229_600) },
    onError: (@Sendable (WhisperrError) -> Void)? = nil,
    // Device-trait defaults are environment-dependent and never pinned by the
    // spec fixtures; DeviceTraitsTests covers them on the real resolver.
    deviceTraits: @escaping @Sendable () -> [String: JSONValue] = { [:] }
) -> WhisperrClient {
    let ids = IDSequence()
    return WhisperrClient(
        apiKey: "wrk_test",
        baseURL: URL(string: "https://api.test")!,
        options: WhisperrOptions(
            flushInterval: 0,
            flushAt: 20,
            maxRetries: maxRetries,
            retryBaseDelay: 0,
            maxRetryDelay: 0,
            enablePersistence: true,
            onError: onError
        ),
        persistence: persistence ?? InMemoryWhisperrPersistence(),
        transport: transport,
        clock: clock,
        idGenerator: { ids.next() },
        sleeper: { _ in },
        deviceTraits: deviceTraits
    )
}

final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextValue += 1
        return "mid-\(nextValue)"
    }
}

final class ErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WhisperrError] = []

    func append(_ error: WhisperrError) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(error)
    }

    var values: [WhisperrError] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

func parseFixtureDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}

/// A client wired for lifecycle tests: a fixed app environment, a settable
/// clock, and no UIKit observer (tests drive the lifecycle hooks directly).
func makeLifecycleClient(
    transport: MockTransport,
    persistence: WhisperrPersistence? = InMemoryWhisperrPersistence(),
    automaticEvents: Bool = true,
    environment: AppEnvironment = .fixture(),
    clock: TestClock = TestClock(),
    deviceTraits: @escaping @Sendable () -> [String: JSONValue] = {
        ["timezone": "Europe/Berlin", "locale": "de-DE"]
    },
    sleeper: @escaping @Sendable (TimeInterval) async -> Void = { _ in },
    maxRetries: Int = 2
) -> WhisperrClient {
    let ids = IDSequence()
    let anonIDs = IDSequence()
    return WhisperrClient(
        apiKey: "wrk_test",
        baseURL: URL(string: "https://api.test")!,
        options: WhisperrOptions(
            flushInterval: 0,
            flushAt: 20,
            maxRetries: maxRetries,
            retryBaseDelay: 0,
            maxRetryDelay: 0,
            enablePersistence: persistence != nil,
            automaticEvents: automaticEvents
        ),
        persistence: persistence,
        transport: transport,
        clock: { clock.now },
        idGenerator: { ids.next() },
        sleeper: sleeper,
        deviceTraits: deviceTraits,
        appEnvironment: { environment },
        anonymousIDGenerator: { "anon-" + anonIDs.next() },
        installsLifecycleObserver: false
    )
}

extension AppEnvironment {
    static func fixture(version: String? = "1.2.0", build: String? = "42") -> AppEnvironment {
        AppEnvironment(
            appVersion: version,
            appBuild: build,
            osName: "iOS",
            osVersion: "18.1",
            platform: "ios"
        )
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_780_229_600)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(seconds)
    }

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

extension MockTransport {
    /// Every event sent in /v1/events/batch requests, in order.
    func sentEvents() -> [[String: JSONValue]] {
        batchBodies().flatMap { body in
            (body.objectValue?["events"]?.arrayValue ?? []).compactMap(\.objectValue)
        }
    }
}
