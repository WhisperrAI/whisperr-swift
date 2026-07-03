import Foundation

/// Process-wide convenience facade for app integrations.
///
/// You can also construct `WhisperrClient` directly when you want explicit
/// dependency injection or more than one client.
public enum Whisperr {
    private static let storage = WhisperrStorage()

    public static func initialize(
        apiKey: String,
        baseURL: URL = kWhisperrDefaultBaseURL,
        options: WhisperrOptions = WhisperrOptions()
    ) async {
        if let existing = await storage.get() {
            await existing.close()
        }
        let client = WhisperrClient(apiKey: apiKey, baseURL: baseURL, options: options)
        await client.start()
        await storage.set(client)
    }

    public static var shared: WhisperrClient? {
        get async {
            await storage.get()
        }
    }
}

private actor WhisperrStorage {
    private var client: WhisperrClient?

    func set(_ client: WhisperrClient) {
        self.client = client
    }

    func get() -> WhisperrClient? {
        client
    }
}
