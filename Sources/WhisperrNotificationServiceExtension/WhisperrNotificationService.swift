import Foundation
#if canImport(UserNotifications) && !os(tvOS)
@preconcurrency import UserNotifications

/// A ready-made Notification Service Extension principal class that adds the
/// image of a Whisperr push (rich push).
///
/// In your Notification Service Extension target, make the principal class a
/// subclass:
///
/// ```swift
/// import WhisperrNotificationServiceExtension
///
/// final class NotificationService: WhisperrNotificationService {}
/// ```
///
/// The push must carry `"mutable-content": 1` in `aps` and an `https` image
/// URL in `whisperr_image_url` (or `image_url`, or FCM's `fcm_options.image`).
/// When the download fails, is too slow, or is not a JPEG, PNG or GIF, the
/// notification shows without the image. It is never dropped.
open class WhisperrNotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var originalContent: UNNotificationContent?
    private var downloadTask: URLSessionTask?

    /// The longest time the image download may take. iOS gives the extension
    /// about 30 seconds in total.
    open var imageDownloadTimeout: TimeInterval {
        WhisperrRichPush.defaultTimeout
    }

    /// The session used for the image download.
    open var urlSession: URLSession {
        .shared
    }

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        lock.lock()
        self.contentHandler = contentHandler
        self.originalContent = request.content
        lock.unlock()

        let task = WhisperrRichPush.attachImage(
            to: content,
            session: urlSession,
            timeout: imageDownloadTimeout
        ) { result in
            self.deliver(result)
        }
        lock.lock()
        downloadTask = task
        lock.unlock()
    }

    open override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = downloadTask
        let original = originalContent
        lock.unlock()
        task?.cancel()
        if let original {
            deliver(original)
        }
    }

    /// Calls the content handler once; later calls do nothing.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        downloadTask = nil
        lock.unlock()
        handler?(content)
    }
}

private final class PendingAttachment: @unchecked Sendable {
    let content: UNMutableNotificationContent
    let completion: (UNMutableNotificationContent) -> Void

    init(content: UNMutableNotificationContent, completion: @escaping (UNMutableNotificationContent) -> Void) {
        self.content = content
        self.completion = completion
    }
}

/// Rich-push helpers for apps that already have their own Notification
/// Service Extension (for example one from another push provider).
public enum WhisperrRichPush {
    /// Data keys that may carry the image URL, in order of preference.
    public static let imageURLKeys = ["whisperr_image_url", "image_url"]
    /// The largest image the helper attaches. Apple's limit for images is 10 MB.
    public static let maxImageBytes = 10 * 1024 * 1024
    /// The default download timeout, in seconds.
    public static let defaultTimeout: TimeInterval = 20

    /// The image URL of a push payload, or nil when it has none. Only `https`
    /// URLs are accepted. Reads the top level, `data`, OneSignal `custom.a`,
    /// and FCM `fcm_options.image`.
    public static func imageURL(in userInfo: [AnyHashable: Any]) -> URL? {
        var sources: [[AnyHashable: Any]] = [userInfo]
        if let data = userInfo["data"] as? [AnyHashable: Any] {
            sources.append(data)
        }
        if let custom = userInfo["custom"] as? [AnyHashable: Any],
           let additional = custom["a"] as? [AnyHashable: Any] {
            sources.append(additional)
        }
        var candidates: [Any?] = []
        for key in imageURLKeys {
            candidates.append(contentsOf: sources.map { $0[key] })
        }
        if let fcm = userInfo["fcm_options"] as? [AnyHashable: Any] {
            candidates.append(fcm["image"])
        }
        for candidate in candidates {
            guard let raw = (candidate as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false else {
                continue
            }
            return url
        }
        return nil
    }

    /// Downloads the payload's image and adds it to `content.attachments`.
    /// `completion` gets `content` back: with the image, or unchanged when
    /// there is no image or anything fails. It is called exactly once, on a
    /// background queue. Returns the download task (cancel it from
    /// `serviceExtensionTimeWillExpire`), or nil when there is nothing to
    /// download, in which case `completion` has already run.
    @discardableResult
    public static func attachImage(
        to content: UNMutableNotificationContent,
        session: URLSession = .shared,
        timeout: TimeInterval = defaultTimeout,
        completion: @escaping (UNMutableNotificationContent) -> Void
    ) -> URLSessionTask? {
        guard let url = imageURL(in: content.userInfo) else {
            completion(content)
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = max(1, timeout)
        // The session calls back once, on its own queue; the box carries the
        // caller's content and handler there.
        let pending = PendingAttachment(content: content, completion: completion)
        let task = session.dataTask(with: request) { data, response, error in
            if error == nil,
               let data,
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let attachment = makeAttachment(data: data, mimeType: http.mimeType, sourceURL: url) {
                pending.content.attachments = pending.content.attachments + [attachment]
            }
            pending.completion(pending.content)
        }
        task.resume()
        // URLRequest.timeoutInterval limits idle time only; this caps the
        // whole download. A cancel ends the task with an error, which takes
        // the fallback path above.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(1, timeout)) { [weak task] in
            task?.cancel()
        }
        return task
    }

    /// Writes the image to a temporary file and wraps it as an attachment.
    /// Returns nil for an empty or oversized body, or an unsupported type.
    static func makeAttachment(data: Data, mimeType: String?, sourceURL: URL) -> UNNotificationAttachment? {
        guard !data.isEmpty, data.count <= maxImageBytes,
              let ext = fileExtension(mimeType: mimeType, url: sourceURL) else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperr-push-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("image.\(ext)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "whisperr-image", url: file, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    /// The file extension iOS needs to read the attachment type: from the
    /// response MIME type, else from the URL path. Only JPEG, PNG and GIF,
    /// the image types notification attachments support.
    static func fileExtension(mimeType: String?, url: URL) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg", "image/pjpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case nil, "application/octet-stream", "binary/octet-stream":
            break // the server did not say; trust the path
        default:
            return nil
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "jpg"
        case "png":
            return "png"
        case "gif":
            return "gif"
        default:
            return nil
        }
    }
}
#endif
