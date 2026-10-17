import Foundation

/// The `error_kind` of an `app_error` sent with `trackError(_:screen:kind:)`.
public enum WhisperrErrorKind: String, Sendable {
    /// An error the app caught and reports (the default).
    case handled
    /// A failed network request, for example an HTTP 5xx.
    case network
    /// A screen that failed to render or load.
    case screen
    /// An uncaught native error. The SDK sends this kind itself.
    case native
}

/// What brought the user into the app, sent as `app_opened.launch_source`.
enum WhisperrLaunchSource: String, Sendable {
    case push
    case shortcut
    case widget
    case email
    case universalLink = "universal_link"
    case deepLink = "deep_link"
    case direct

    /// Higher wins when several signals arrive in the attribution window.
    var rank: Int {
        switch self {
        case .push: return 6
        case .shortcut: return 5
        case .widget: return 4
        case .email: return 3
        case .universalLink: return 2
        case .deepLink: return 1
        case .direct: return 0
        }
    }
}

/// A launch source and the `app_opened` properties that come with it
/// (`whisperr_message_id`, `link_route`, `link_host`, `utm_*`).
struct WhisperrLaunchSignal: Sendable, Equatable {
    let source: WhisperrLaunchSource
    let properties: [String: JSONValue]

    /// Every key a launch signal can set on `app_opened`.
    static let keys = [
        "launch_source", "whisperr_message_id", "link_route", "link_host",
        "utm_source", "utm_medium", "utm_campaign"
    ]

    static func push(messageID: String) -> WhisperrLaunchSignal {
        WhisperrLaunchSignal(
            source: .push,
            properties: ["whisperr_message_id": .string(WhisperrSignals.truncate(messageID, 128))]
        )
    }

    /// A deep link (custom scheme) or universal link (http/https). `wsrc=widget`
    /// or `wsrc=shortcut` in the query marks a widget or shortcut, `wmid` an
    /// email link. Only the redacted path, the host of an http(s) link and the
    /// `utm_*` values are kept.
    static func link(_ url: URL) -> WhisperrLaunchSignal? {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value, !raw.isEmpty else {
                return nil
            }
            return raw
        }

        var properties: [String: JSONValue] = [:]
        let isWeb = scheme == "http" || scheme == "https"
        let path: String
        if isWeb {
            path = components?.percentEncodedPath ?? url.path
            if let host = url.host, !host.isEmpty {
                properties["link_host"] = .string(host.lowercased())
            }
        } else {
            // A custom scheme has no host: the route is everything between
            // `scheme://` and the query or fragment.
            var rest = Substring(url.absoluteString)
            rest = rest.dropFirst(scheme.count + 1)
            if rest.hasPrefix("//") {
                rest = rest.dropFirst(2)
            }
            if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                rest = rest[..<cut]
            }
            path = String(rest)
        }
        properties["link_route"] = .string(WhisperrSignals.redactRoute(path))
        for key in ["utm_source", "utm_medium", "utm_campaign"] {
            if let utm = value(key) {
                properties[key] = .string(WhisperrSignals.truncate(utm, 128))
            }
        }

        let source: WhisperrLaunchSource
        switch value("wsrc")?.lowercased() {
        case "shortcut"?:
            source = .shortcut
        case "widget"?:
            source = .widget
        default:
            if let wmid = value("wmid") {
                source = .email
                properties["whisperr_message_id"] = .string(WhisperrSignals.truncate(wmid, 128))
            } else {
                source = isWeb ? .universalLink : .deepLink
            }
        }
        return WhisperrLaunchSignal(source: source, properties: properties)
    }
}

/// Per foreground visit counters for `app_backgrounded`.
struct WhisperrVisitCounters: Sendable {
    var screens = 0
    var uniqueScreens: Set<String> = []
    var events = 0
    var errors = 0
}

enum WhisperrSignals {
    /// The path with its identifiers replaced by `:id`: a segment that is all
    /// digits, a UUID, or 16 characters or longer. At most 256 characters.
    static func redactRoute(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { raw -> String in
            let segment = String(raw)
            guard !segment.isEmpty else {
                return segment
            }
            let decoded = segment.removingPercentEncoding ?? segment
            if decoded.allSatisfy({ $0.isASCII && $0.isNumber })
                || UUID(uuidString: decoded) != nil
                || decoded.count >= 16 {
                return ":id"
            }
            return segment
        }
        var route = segments.joined(separator: "/")
        if !route.hasPrefix("/") {
            route = "/" + route
        }
        return truncate(route, 256)
    }

    /// First 16 lowercase hex characters of SHA-256 over the error name and the
    /// top three frame function names, joined by `\n`.
    static func fingerprint(name: String, frames: [String]) -> String {
        let input = ([name] + frames.prefix(3)).joined(separator: "\n")
        return String(sha256Hex(input).prefix(16))
    }

    /// SHA-256 (FIPS 180-4) as lowercase hex. Local so the fingerprint needs
    /// no CryptoKit or CommonCrypto import; inputs are a few short strings.
    static func sha256Hex(_ input: String) -> String {
        var message = Array(input.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        var words = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let base = chunk + index * 4
                words[index] = UInt32(message[base]) << 24 | UInt32(message[base + 1]) << 16
                    | UInt32(message[base + 2]) << 8 | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotr(words[index - 15], 7) ^ rotr(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let s1 = rotr(words[index - 2], 17) ^ rotr(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ sha256K[index] &+ words[index]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
        }
        let hex = Array("0123456789abcdef")
        var out = ""
        for value in hash {
            for shift in stride(from: 28, through: 0, by: -4) {
                out.append(hex[Int((value >> UInt32(shift)) & 0xf)])
            }
        }
        return out
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static let sha256K: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    /// The function name of one `callStackSymbols` line
    /// (`3   MyApp   0x0000000100abc123 $s5MyApp4loadyyF + 52`), without the
    /// image, address and offset.
    static func frameName(_ symbol: String) -> String? {
        let parts = symbol.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else {
            return nil
        }
        var name = parts[3...]
        if let plus = name.firstIndex(of: "+") {
            name = name[name.startIndex..<plus]
        }
        let joined = name.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// The type name of an error, never its message. A bridged `NSError`
    /// reports its domain and code.
    static func errorName(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        if typeName == "NSError" || typeName.hasPrefix("_") {
            let nsError = error as NSError
            return truncate("\(nsError.domain)_\(nsError.code)", 64)
        }
        return truncate(typeName, 64)
    }

    static func truncate(_ value: String, _ limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit)) : value
    }

    /// A new session id: `sess_` and a lowercase UUID v4.
    static func newSessionID() -> String {
        "sess_" + UUID().uuidString.lowercased()
    }
}

// MARK: - Unclean-shutdown flag

/// What the SDK knows about the running foreground visit. Written on each move
/// to the foreground, cleared on each move to the background. A marker still
/// set at the next launch means the app ended while in the foreground.
struct WhisperrRunMarker: Codable, Equatable, Sendable {
    var sessionID: String?
    var screen: String?
    var appVersion: String?
    /// Set by the uncaught-exception handler.
    var fatal: Bool?
}

/// Synchronous store for the run marker, so the uncaught-exception handler can
/// write it before the process ends. UserDefaults in apps, memory in tests.
final class WhisperrRunMarkerStore: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let key: String
    private var memory: WhisperrRunMarker?
    /// The marker set aside while the app is inactive (see `park()`).
    private var parked: WhisperrRunMarker?

    init(defaults: UserDefaults?, key: String = "net.whisperr.sdk.run") {
        self.defaults = defaults
        self.key = key
    }

    static func inMemory() -> WhisperrRunMarkerStore {
        WhisperrRunMarkerStore(defaults: nil)
    }

    func load() -> WhisperrRunMarker? {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    func save(_ marker: WhisperrRunMarker?) {
        lock.lock()
        defer { lock.unlock() }
        parked = nil
        write(marker)
    }

    /// The app became inactive: clear the stored marker and keep it in
    /// memory, so a kill from the app switcher is not reported as a crash.
    func park() {
        lock.lock()
        defer { lock.unlock() }
        guard let marker = read() else {
            return
        }
        parked = marker
        write(nil)
        defaults?.synchronize()
    }

    /// The app is active again: store the parked marker.
    func unpark() {
        lock.lock()
        defer { lock.unlock() }
        guard let marker = parked else {
            return
        }
        parked = nil
        write(marker)
    }

    /// Changes the marker if one is set (the app is in the foreground).
    func update(_ change: (inout WhisperrRunMarker) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if var marker = read() {
            change(&marker)
            write(marker)
        } else if var marker = parked {
            change(&marker)
            parked = marker
        }
    }

    func markFatal() {
        update { $0.fatal = true }
        defaults?.synchronize()
    }

    private func read() -> WhisperrRunMarker? {
        guard let defaults else {
            return memory
        }
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(WhisperrRunMarker.self, from: data)
    }

    private func write(_ marker: WhisperrRunMarker?) {
        guard let defaults else {
            memory = marker
            return
        }
        if let marker, let data = try? JSONEncoder().encode(marker) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Uncaught exceptions

#if canImport(ObjectiveC)

/// Installs one process-wide `NSSetUncaughtExceptionHandler`, chained to the
/// handler that was installed before it, and forwards each uncaught exception
/// to the attached client as a fatal `app_error`.
final class WhisperrErrorCapture: @unchecked Sendable {
    static let shared = WhisperrErrorCapture()

    /// How long the handler waits for the client to queue the `app_error`
    /// before it hands over to the previous handler.
    static let fatalWait: TimeInterval = 1

    private let lock = NSLock()
    private weak var client: WhisperrClient?
    private var runMarkers: WhisperrRunMarkerStore?
    private var installed = false
    private var previous: (@convention(c) (NSException) -> Void)?

    func attach(_ client: WhisperrClient, runMarkers: WhisperrRunMarkerStore) {
        lock.lock()
        defer { lock.unlock() }
        self.client = client
        self.runMarkers = runMarkers
        guard !installed else {
            return
        }
        installed = true
        previous = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(whisperrUncaughtExceptionHandler)
    }

    func detach(_ client: WhisperrClient) {
        lock.lock()
        defer { lock.unlock() }
        if self.client === client {
            self.client = nil
            self.runMarkers = nil
        }
    }

    /// Forgets the attached client and the chained handler, so a test can
    /// install the handler again on top of its own.
    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        client = nil
        runMarkers = nil
        installed = false
        previous = nil
    }

    func handle(_ exception: NSException) {
        lock.lock()
        let client = self.client
        let runMarkers = self.runMarkers
        let previous = self.previous
        lock.unlock()

        if let client {
            runMarkers?.markFatal()
            let name = WhisperrSignals.truncate(exception.name.rawValue, 64)
            let frames = Array(exception.callStackSymbols.compactMap(WhisperrSignals.frameName).prefix(3))
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await client.handleUncaughtError(name: name, frames: frames, fatal: true)
                done.signal()
            }
            _ = done.wait(timeout: .now() + Self.fatalWait)
        }
        previous?(exception)
    }
}

private func whisperrUncaughtExceptionHandler(_ exception: NSException) {
    WhisperrErrorCapture.shared.handle(exception)
}
#endif
