import Foundation

public protocol WhisperrPersistence: Sendable {
    func load() async -> Data?
    func save(_ data: Data?) async
}

/// UserDefaults-backed queue persistence for Apple platforms.
public final class UserDefaultsWhisperrPersistence: WhisperrPersistence, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "net.whisperr.sdk.queue"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() async -> Data? {
        defaults.data(forKey: key)
    }

    public func save(_ data: Data?) async {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory persistence, useful in tests or ephemeral runtimes.
public actor InMemoryWhisperrPersistence: WhisperrPersistence {
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func load() async -> Data? {
        data
    }

    public func save(_ data: Data?) async {
        self.data = data
    }
}
