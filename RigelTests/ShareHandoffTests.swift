import XCTest

final class ShareHandoffTests: XCTestCase {
    private enum LoadError: Error {
        case unavailable
    }

    private typealias LoadCompletion = (Result<URL, Error>) -> Void
    private typealias OpenCompletion = () -> Void

    func testLoadsEligibleAttachmentsInOrderAndCompletesAfterOpen() {
        var loadedProviders: [Int] = []
        var loadCompletions: [LoadCompletion] = []
        var openedURLs: [URL] = []
        var openCompletions: [OpenCompletion] = []
        var completionCount = 0
        var timeout: (() -> Void)?

        let coordinator = ShareHandoffCoordinator(
            providers: [0, 1, 2],
            load: { provider, completion in
                loadedProviders.append(provider)
                loadCompletions.append(completion)
            },
            openURL: { url, completion in
                openedURLs.append(url)
                openCompletions.append(completion)
            },
            complete: {
                completionCount += 1
            },
            scheduleTimeout: { callback in
                timeout = callback
            }
        )
        coordinator.start()

        XCTAssertEqual(loadedProviders, [0])
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(completionCount, 0)
        XCTAssertNotNil(timeout)

        loadCompletions[0](.failure(LoadError.unavailable))
        XCTAssertEqual(loadedProviders, [0, 1])

        let expectedURL = URL(string: "https://example.com/second")!
        loadCompletions[1](.success(expectedURL))
        XCTAssertEqual(openedURLs, [expectedURL])
        XCTAssertEqual(completionCount, 0)

        openCompletions[0]()
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(loadedProviders, [0, 1])
    }

    func testIgnoresDuplicateAndStaleProviderAndOpenCallbacks() {
        var loadCompletions: [LoadCompletion] = []
        var openedURLs: [URL] = []
        var openCompletions: [OpenCompletion] = []
        var completionCount = 0
        var timeout: (() -> Void)?

        let coordinator = ShareHandoffCoordinator(
            providers: [0, 1],
            load: { _, completion in
                loadCompletions.append(completion)
            },
            openURL: { url, completion in
                openedURLs.append(url)
                openCompletions.append(completion)
            },
            complete: {
                completionCount += 1
            },
            scheduleTimeout: { callback in
                timeout = callback
            }
        )
        coordinator.start()

        loadCompletions[0](.failure(LoadError.unavailable))
        let staleURL = URL(string: "https://example.com/stale")!
        loadCompletions[0](.success(staleURL))
        XCTAssertEqual(loadCompletions.count, 2)
        XCTAssertTrue(openedURLs.isEmpty)

        let expectedURL = URL(string: "https://example.com/current")!
        loadCompletions[1](.success(expectedURL))
        loadCompletions[1](.success(staleURL))
        XCTAssertEqual(openedURLs, [expectedURL])
        XCTAssertEqual(completionCount, 0)

        openCompletions[0]()
        openCompletions[0]()
        timeout?()
        XCTAssertEqual(completionCount, 1)
    }

    func testTimeoutCompletesOnceAndRejectsLateProviderAndOpenCallbacks() {
        var loadCompletions: [LoadCompletion] = []
        var openCompletions: [OpenCompletion] = []
        var completionCount = 0
        var timeout: (() -> Void)?

        let coordinator = ShareHandoffCoordinator(
            providers: [0],
            load: { _, completion in
                loadCompletions.append(completion)
            },
            openURL: { _, completion in
                openCompletions.append(completion)
            },
            complete: {
                completionCount += 1
            },
            scheduleTimeout: { callback in
                timeout = callback
            }
        )
        coordinator.start()

        guard let timeout else {
            return XCTFail("coordinator did not schedule a timeout")
        }
        timeout()
        timeout()
        XCTAssertEqual(completionCount, 1)

        loadCompletions[0](.success(URL(string: "https://example.com/late")!))
        XCTAssertTrue(openCompletions.isEmpty)
        XCTAssertEqual(completionCount, 1)
    }
    func testCompletesAfterAllEligibleProvidersFail() {
        var loadCompletions: [LoadCompletion] = []
        var openedURLs: [URL] = []
        var completionCount = 0
        var timeout: (() -> Void)?

        let coordinator = ShareHandoffCoordinator(
            providers: [0, 1],
            load: { _, completion in
                loadCompletions.append(completion)
            },
            openURL: { url, _ in
                openedURLs.append(url)
            },
            complete: {
                completionCount += 1
            },
            scheduleTimeout: { callback in
                timeout = callback
            }
        )
        coordinator.start()

        loadCompletions[0](.failure(LoadError.unavailable))
        XCTAssertEqual(loadCompletions.count, 2)
        loadCompletions[1](.failure(LoadError.unavailable))
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(completionCount, 1)
        timeout?()
        XCTAssertEqual(completionCount, 1)
    }
}
