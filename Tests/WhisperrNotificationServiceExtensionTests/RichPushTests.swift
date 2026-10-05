import XCTest
#if canImport(UserNotifications) && !os(tvOS)
import UserNotifications
@testable import WhisperrNotificationServiceExtension

/// Serves canned responses to the rich-push download.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var mimeType: String? = "image/png"
        var body = Data()
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private static var _stub = Stub()
    static var stub: Stub {
        get { lock.lock(); defer { lock.unlock() }; return _stub }
        set { lock.lock(); defer { lock.unlock() }; _stub = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.stub
        let respond = { [weak self] in
            guard let self, let url = self.request.url else { return }
            var headers: [String: String] = [:]
            if let mimeType = stub.mimeType {
                headers["Content-Type"] = mimeType
            }
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}

final class RichPushTests: XCTestCase {
    /// A 1x1 PNG.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func content(_ userInfo: [AnyHashable: Any]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Your streak is waiting"
        content.userInfo = userInfo
        return content
    }

    private func attach(_ content: UNMutableNotificationContent, timeout: TimeInterval = 5) -> UNMutableNotificationContent {
        let done = expectation(description: "completion")
        var result: UNMutableNotificationContent?
        WhisperrRichPush.attachImage(to: content, session: session, timeout: timeout) { output in
            result = output
            done.fulfill()
        }
        wait(for: [done], timeout: timeout + 5)
        return result!
    }

    func testImageURLKeys() {
        XCTAssertEqual(
            WhisperrRichPush.imageURL(in: ["whisperr_image_url": "https://cdn.example.com/a.png", "image_url": "https://cdn.example.com/b.png"]),
            URL(string: "https://cdn.example.com/a.png")
        )
        XCTAssertEqual(
            WhisperrRichPush.imageURL(in: ["data": ["image_url": "https://cdn.example.com/b.png"]]),
            URL(string: "https://cdn.example.com/b.png")
        )
        XCTAssertEqual(
            WhisperrRichPush.imageURL(in: ["custom": ["a": ["whisperr_image_url": "https://cdn.example.com/c.png"]]]),
            URL(string: "https://cdn.example.com/c.png")
        )
        XCTAssertEqual(
            WhisperrRichPush.imageURL(in: ["fcm_options": ["image": "https://cdn.example.com/d.png"]]),
            URL(string: "https://cdn.example.com/d.png")
        )
    }

    func testOnlyHTTPSImagesAreAccepted() {
        XCTAssertNil(WhisperrRichPush.imageURL(in: ["whisperr_image_url": "http://cdn.example.com/a.png"]))
        XCTAssertNil(WhisperrRichPush.imageURL(in: ["whisperr_image_url": "file:///etc/passwd"]))
        XCTAssertNil(WhisperrRichPush.imageURL(in: ["whisperr_image_url": "not a url"]))
        XCTAssertNil(WhisperrRichPush.imageURL(in: ["aps": ["alert": "Hi"]]))
    }

    func testFileExtension() {
        let url = URL(string: "https://cdn.example.com/image")!
        XCTAssertEqual(WhisperrRichPush.fileExtension(mimeType: "image/jpeg", url: url), "jpg")
        XCTAssertEqual(WhisperrRichPush.fileExtension(mimeType: "IMAGE/PNG", url: url), "png")
        XCTAssertEqual(WhisperrRichPush.fileExtension(mimeType: "image/gif", url: url), "gif")
        XCTAssertNil(WhisperrRichPush.fileExtension(mimeType: "text/html", url: URL(string: "https://x.com/a.png")!))
        XCTAssertEqual(WhisperrRichPush.fileExtension(mimeType: "application/octet-stream", url: URL(string: "https://x.com/a.JPEG")!), "jpg")
        XCTAssertNil(WhisperrRichPush.fileExtension(mimeType: nil, url: URL(string: "https://x.com/a.webp")!))
    }

    func testNoImageCompletesAtOnceWithTheSameContent() {
        let input = content(["whisperr_message_id": "m1"])
        var output: UNMutableNotificationContent?
        let task = WhisperrRichPush.attachImage(to: input, session: session) { output = $0 }
        XCTAssertNil(task)
        XCTAssertTrue(output === input)
        XCTAssertTrue(input.attachments.isEmpty)
    }

    func testDownloadedImageIsAttached() {
        StubURLProtocol.stub = .init(status: 200, mimeType: "image/png", body: png)
        let output = attach(content(["whisperr_image_url": "https://cdn.example.com/hero"]))
        XCTAssertEqual(output.attachments.count, 1)
        XCTAssertEqual(output.attachments.first?.identifier, "whisperr-image")
        XCTAssertEqual(output.title, "Your streak is waiting")
    }

    func testHTTPErrorFallsBackToTheOriginalContent() {
        StubURLProtocol.stub = .init(status: 404, mimeType: "text/html", body: Data("missing".utf8))
        let output = attach(content(["whisperr_image_url": "https://cdn.example.com/hero.png"]))
        XCTAssertTrue(output.attachments.isEmpty)
        XCTAssertEqual(output.title, "Your streak is waiting")
    }

    func testUnsupportedTypeFallsBack() {
        StubURLProtocol.stub = .init(status: 200, mimeType: "image/webp", body: png)
        let output = attach(content(["whisperr_image_url": "https://cdn.example.com/hero.webp"]))
        XCTAssertTrue(output.attachments.isEmpty)
    }

    func testOversizedImageFallsBack() {
        StubURLProtocol.stub = .init(status: 200, mimeType: "image/png", body: Data(count: WhisperrRichPush.maxImageBytes + 1))
        let output = attach(content(["whisperr_image_url": "https://cdn.example.com/huge.png"]))
        XCTAssertTrue(output.attachments.isEmpty)
    }

    func testSlowDownloadTimesOutAndFallsBack() {
        StubURLProtocol.stub = .init(status: 200, mimeType: "image/png", body: png, delay: 4)
        let start = Date()
        let output = attach(content(["whisperr_image_url": "https://cdn.example.com/slow.png"]), timeout: 1)
        XCTAssertTrue(output.attachments.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
    }
}
#endif
