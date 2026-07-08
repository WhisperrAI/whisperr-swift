import Foundation
@testable import Whisperr

struct WireSpec: Decodable {
    let cases: [WireCase]
}

struct WireCase: Decodable {
    let name: String
    let op: String
    let scenario: [String: JSONValue]
    let endpoint: String
    let expectedEvent: [String: JSONValue]?
    let expectedBody: [String: JSONValue]?
    let contextMustContain: [String]?
    let occurredAtRfc3339Z: Bool?
    let expectedOccurredAt: String?
}

struct PushSpec: Decodable {
    let cases: [PushCase]
}

struct PushCase: Decodable {
    let name: String
    let steps: [PushStep]
    let expectedBodies: [JSONValue]
}

/// One step of a push case: exactly one of `identify` / `setPushToken` /
/// `restart` / `reset` is set. `restart` tears the client down and builds a
/// fresh one sharing the same persistence, simulating an app relaunch; `reset`
/// maps to reset()/logout.
struct PushStep: Decodable {
    let identify: [String: JSONValue]?
    let setPushToken: String?
    let restart: Bool?
    let reset: Bool?
}

struct BehaviorSpec: Decodable {
    let cases: [BehaviorCase]
}

struct BehaviorCase: Decodable {
    let name: String
    let scenario: BehaviorScenario
    let clientOptions: BehaviorClientOptions?
    let firstResponse: BehaviorResponse
    let recoveryResponse: BehaviorResponse
    let expect: BehaviorExpect
}

struct BehaviorScenario: Decodable {
    let externalUserId: String
    let eventType: String
    let properties: [String: JSONValue]?
}

struct BehaviorClientOptions: Decodable {
    let maxRetries: Int?
}

struct BehaviorResponse: Decodable {
    let classification: String
    let status: Int
}

struct BehaviorExpect: Decodable {
    let errorType: String
    let retainedAfterFirstFlush: Bool
    let deliveredAfterRecovery: Bool
    let retriesAfterRecovery: Bool
    let stableMessageIdOnRetry: Bool?
}

func loadSpec<T: Decodable>(fileName: String, envKey: String) throws -> T {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment

    if let explicit = env[envKey], !explicit.isEmpty, fm.fileExists(atPath: explicit) {
        return try decodeSpec(at: URL(fileURLWithPath: explicit))
    }

    if envKey != "WHISPERR_SPEC_PATH",
       let wire = env["WHISPERR_SPEC_PATH"],
       !wire.isEmpty {
        let sibling = URL(fileURLWithPath: wire).deletingLastPathComponent().appendingPathComponent(fileName)
        if fm.fileExists(atPath: sibling.path) {
            return try decodeSpec(at: sibling)
        }
    }

    let local = URL(fileURLWithPath: fm.currentDirectoryPath)
        .deletingLastPathComponent()
        .appendingPathComponent("whisperr-spec/conformance")
        .appendingPathComponent(fileName)
    if fm.fileExists(atPath: local.path) {
        return try decodeSpec(at: local)
    }

    throw NSError(
        domain: "WhisperrSpec",
        code: 1,
        userInfo: [
            NSLocalizedDescriptionKey: "Set \(envKey) or WHISPERR_SPEC_PATH to a whisperr-spec fixture."
        ]
    )
}

private func decodeSpec<T: Decodable>(at url: URL) throws -> T {
    let data = try Data(contentsOf: url)
    return try JSONDecoder.whisperr.decode(T.self, from: data)
}
