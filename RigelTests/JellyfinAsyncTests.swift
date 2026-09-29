import XCTest
@testable import Rigel

final class JellyfinAsyncTests: XCTestCase {

    func testResumesWithValue() async throws {
        let value = try await JellyfinAsync.run { completion in
            completion(42, nil)
        } as Int
        XCTAssertEqual(value, 42)
    }

    func testResumesWithError() async {
        do {
            _ = try await JellyfinAsync.run { completion in
                completion(nil, NSError(domain: "test", code: 7))
            } as Int
            XCTFail("expected the Kotlin error to be rethrown")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "test")
            XCTAssertEqual(error.code, 7)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testSecondCallbackIsDropped() async throws {
        // Without the once-only gate, the second resume would crash.
        let value = try await JellyfinAsync.run { completion in
            completion(1, nil)
            completion(2, nil)
        } as Int
        XCTAssertEqual(value, 1)
    }

    func testNilValueAndNilErrorResumesAsEmptyResponseFailure() async {
        do {
            _ = try await JellyfinAsync.run { completion in
                completion(nil, nil)
            } as Int
            XCTFail("expected a failure for a nil/nil completion")
        } catch {}
    }

    func testCancelResumesPendingContinuationAndDropsLateCallback() async throws {
        let task = Task<Int, Error> {
            try await JellyfinAsync.run { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    completion(99, nil)
                }
            }
        }
        // Let the task install its continuation before cancelling.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        // Let the late callback fire; a double resume would crash the run.
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func testCancelBeforeInstallResumesImmediately() async throws {
        let bodyInvoked = DispatchSemaphore(value: 0)
        let reachedInstall = DispatchSemaphore(value: 0)
        let allowInstall = DispatchSemaphore(value: 0)
        let task = Task<Int, Error> {
            reachedInstall.signal()
            allowInstall.wait()
            return try await JellyfinAsync.run { completion in
                bodyInvoked.signal()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    completion(5, nil)
                }
            } as Int
        }
        XCTAssertEqual(reachedInstall.wait(timeout: .now() + 1), .success)
        task.cancel()
        allowInstall.signal()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        if bodyInvoked.wait(timeout: .now() + 0.05) == .success {
            XCTFail("the request body must not start when cancellation wins before install")
        }
    }
}
