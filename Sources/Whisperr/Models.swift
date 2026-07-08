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
    let body: [String: JSONValue]
}

public enum WhisperrSendResult: Sendable {
    case ok
    case retry
    case auth(Int?)
    case drop(Int?)
}
