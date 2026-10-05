import Foundation

/// Contact channel attached to a user through `identify`.
public enum WhisperrChannelType: String, Codable, Sendable {
    case email
    case sms
    case push
}

/// A reachable address or token for a user.
public struct WhisperrChannel: Equatable, Sendable {
    public let type: WhisperrChannelType
    public let address: String
    public let optedIn: Bool?
    public let verified: Bool?

    public init(
        type: WhisperrChannelType,
        address: String,
        optedIn: Bool? = nil,
        verified: Bool? = nil
    ) {
        self.type = type
        self.address = address
        self.optedIn = optedIn
        self.verified = verified
    }

    public static func email(
        _ address: String,
        optedIn: Bool? = nil,
        verified: Bool? = nil
    ) -> WhisperrChannel {
        WhisperrChannel(type: .email, address: address, optedIn: optedIn, verified: verified)
    }

    public static func sms(
        _ address: String,
        optedIn: Bool? = nil,
        verified: Bool? = nil
    ) -> WhisperrChannel {
        WhisperrChannel(type: .sms, address: address, optedIn: optedIn, verified: verified)
    }

    public static func push(
        _ token: String,
        optedIn: Bool? = nil,
        verified: Bool? = nil
    ) -> WhisperrChannel {
        WhisperrChannel(type: .push, address: token, optedIn: optedIn, verified: verified)
    }

    var body: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "channel": .string(type.rawValue),
            "address": .string(address)
        ]
        if let optedIn {
            out["opted_in"] = .bool(optedIn)
        }
        if let verified {
            out["verified"] = .bool(verified)
        }
        return out
    }
}

public enum WhisperrErrorType: String, Codable, Sendable {
    case auth
    case dropped
    case retryExhausted = "retry_exhausted"
}

/// Delivery issue surfaced after the SDK classifies a backend or network response.
public struct WhisperrError: Error, Equatable, Sendable {
    public let type: WhisperrErrorType
    public let message: String
    public let status: Int?

    public init(type: WhisperrErrorType, message: String, status: Int? = nil) {
        self.type = type
        self.message = message
        self.status = status
    }
}

public enum WhisperrClientError: Error, Equatable, Sendable {
    case emptyExternalUserID
    /// No longer thrown: `track()` before `identify()` is sent under the
    /// device's `anonymous_id`. Kept for source compatibility.
    case missingUserID
    case emptyEventType
    case emptyPushToken
    case closed
}

public struct WhisperrOptions: Sendable {
    public var flushInterval: TimeInterval
    public var flushAt: Int
    public var maxBatchSize: Int
    public var maxQueueSize: Int
    public var maxRetries: Int
    public var retryBaseDelay: TimeInterval
    public var maxRetryDelay: TimeInterval
    public var requestTimeout: TimeInterval
    public var enablePersistence: Bool
    public var debug: Bool
    /// Sends `app_installed`, `app_updated`, `app_opened` and
    /// `app_backgrounded` automatically on UIKit platforms (iOS, iPadOS, tvOS,
    /// visionOS, Mac Catalyst). On by default. The flush when the app goes to
    /// the background happens whatever this value is.
    public var automaticEvents: Bool
    public var onError: (@Sendable (WhisperrError) -> Void)?

    public init(
        flushInterval: TimeInterval = 15,
        flushAt: Int = 20,
        maxBatchSize: Int = 500,
        maxQueueSize: Int = 1_000,
        maxRetries: Int = 6,
        retryBaseDelay: TimeInterval = 1,
        maxRetryDelay: TimeInterval = 300,
        requestTimeout: TimeInterval = 30,
        enablePersistence: Bool = true,
        debug: Bool = false,
        automaticEvents: Bool = true,
        onError: (@Sendable (WhisperrError) -> Void)? = nil
    ) {
        self.flushInterval = max(0, flushInterval)
        self.flushAt = max(1, flushAt)
        self.maxBatchSize = min(max(1, maxBatchSize), 500)
        self.maxQueueSize = max(1, maxQueueSize)
        self.maxRetries = max(0, maxRetries)
        self.retryBaseDelay = max(0, retryBaseDelay)
        self.maxRetryDelay = max(0, maxRetryDelay)
        self.requestTimeout = max(1, requestTimeout)
        self.enablePersistence = enablePersistence
        self.debug = debug
        self.automaticEvents = automaticEvents
        self.onError = onError
    }
}

enum QueuedOperationKind: String, Codable, Sendable {
    case identify
    case track
}

struct QueuedOperation: Codable, Equatable, Sendable {
    let id: String
    let kind: QueuedOperationKind
    var body: [String: JSONValue]
}

/// Everything the client persists between launches: the pending queue, the
/// identified user, and the last (user, token) pair delivered by push-token
/// capture — so same-token dedupe and rotation opt-out survive app restarts.
/// It also holds the anonymous handle, the opt-out flag, the last app
/// version seen (for `app_installed` / `app_updated`) and the push message ids
/// already reported as opened. Fields added after 0.2.2 are optional so older
/// state still decodes.
struct PersistedState: Codable, Equatable, Sendable {
    var queue: [QueuedOperation] = []
    var userID: String?
    var lastPushUserID: String?
    var lastPushToken: String?
    var anonymousID: String?
    var optedOut: Bool?
    var appVersion: String?
    var appBuild: String?
    var openedPushMessageIDs: [String]?

    var isEmpty: Bool {
        queue.isEmpty && userID == nil && lastPushUserID == nil && lastPushToken == nil
            && anonymousID == nil && optedOut != true && appVersion == nil && appBuild == nil
            && (openedPushMessageIDs ?? []).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case queue
        case userID = "user_id"
        case lastPushUserID = "last_push_user_id"
        case lastPushToken = "last_push_token"
        case anonymousID = "anonymous_id"
        case optedOut = "opted_out"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case openedPushMessageIDs = "opened_push_message_ids"
    }
}

public enum WhisperrSendResult: Sendable, Equatable {
    case ok
    case retry
    /// A retryable response (`429` / `503`) whose `Retry-After` header asked
    /// for this many seconds before the next attempt.
    case retryAfter(TimeInterval)
    case auth(Int?)
    case drop(Int?)
}
