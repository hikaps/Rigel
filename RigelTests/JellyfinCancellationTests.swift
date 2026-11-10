import XCTest
import ComposeApp
@testable import Rigel

/// Guards the completion-handler error contract: Kotlin/Native delivers
/// cancelled browse/search as NSError (domain "KotlinException") wrapping a
/// KotlinThrowable that does not conform to Swift Error. Those must classify
/// as cancellation — not red Jellyfin request failures — while real request
/// failures must still surface.
final class JellyfinCancellationTests: XCTestCase {
    func testKotlinProducedCancellationErrorClassifiesAsCancellation() {
        // asError() performs the exact Kotlin→NSError conversion the
        // @Throws completion handlers receive.
        let error = JellyfinInterop.shared.makeCancellationThrowable().asError()
        XCTAssertTrue(JellyfinCancellation.isCancellation(error))
    }

    func testManualKotlinExceptionEnvelopeClassifiesAsCancellation() {
        let throwable = JellyfinInterop.shared.makeCancellationThrowable()
        let error = NSError(
            domain: "KotlinException",
            code: 0,
            userInfo: ["KotlinException": throwable]
        )
        XCTAssertTrue(JellyfinCancellation.isCancellation(error))
    }

    func testKotlinRequestExceptionIsNotCancellation() {
        let error = JellyfinRequestException(statusCode: 401).asError()
        XCTAssertFalse(JellyfinCancellation.isCancellation(error))
    }

    func testSwiftCancellationErrorIsCancellation() {
        XCTAssertTrue(JellyfinCancellation.isCancellation(CancellationError()))
    }

    func testPlainNSErrorIsNotCancellation() {
        XCTAssertFalse(
            JellyfinCancellation.isCancellation(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            )
        )
    }
    func testHTTPStatusIsClassifiedFromKotlinThrowable() {
        let unauthorized = JellyfinInterop.shared.makeRequestException(statusCode: 401).asError()
        let forbidden = JellyfinInterop.shared.makeRequestException(statusCode: 403).asError()

        XCTAssertEqual(JellyfinCancellation.httpStatusCode(unauthorized), 401)
        XCTAssertEqual(JellyfinCancellation.httpStatusCode(forbidden), 403)
        XCTAssertNil(JellyfinCancellation.httpStatusCode(NSError(domain: "test", code: 500)))
    }
}
