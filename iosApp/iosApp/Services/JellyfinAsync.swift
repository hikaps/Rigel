import Foundation
import ComposeApp

/// Awaits a Kotlin completion handler as async/await with cancellation.
/// Kotlin calls cannot be cancelled for real, so the gate guarantees the
/// continuation resumes exactly once: cancellation wins the race and the
/// Kotlin callback that arrives later is dropped.
enum JellyfinAsync {
    static func run<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) async throws -> T {
        let gate = KotlinResumeGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                gate.install(continuation)
                body { value, error in gate.deliver(value: value, error: error) }
            }
        } onCancel: {
            gate.cancel()
        }
    }
}

final class KotlinResumeGate<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false
    private var resumed = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let alreadyCancelled: Bool = lock.withLock {
            if cancelled {
                resumed = true
                return true
            }
            self.continuation = continuation
            return false
        }
        if alreadyCancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    func deliver(value: T?, error: Error?) {
        let continuation: CheckedContinuation<T, Error>? = lock.withLock {
            guard !resumed else { return nil }
            resumed = true
            return self.continuation
        }
        guard let continuation else { return }
        if let error {
            continuation.resume(throwing: error)
        } else if let value {
            continuation.resume(returning: value)
        } else {
            continuation.resume(throwing: JellyfinAsyncError.emptyResponse)
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<T, Error>? = lock.withLock {
            cancelled = true
            guard !resumed else { return nil }
            resumed = true
            return self.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

enum JellyfinAsyncError: LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        "The request returned no result."
    }
}
@MainActor
protocol JellyfinServing {
    func authenticateAsync(base: String, username: String, password: String, deviceId: String) async -> JellyfinAuth?
    func browseAsync(
        base: String,
        token: String,
        userId: String,
        parentId: String?,
        startIndex: Int32,
        limit: Int32,
        order: JellyfinBrowseOrder
    ) async throws -> JellyfinItemPage
    func searchAsync(
        base: String,
        token: String,
        userId: String,
        term: String,
        filter: JellyfinSearchFilter,
        startIndex: Int32,
        limit: Int32
    ) async throws -> JellyfinItemPage
    func itemMediaSourcesAsync(base: String, token: String, userId: String, itemId: String) async throws -> [JellyfinMediaSource]
}

@MainActor extension JellyfinClient: JellyfinServing {
    func authenticateAsync(
        base: String,
        username: String,
        password: String,
        deviceId: String
    ) async -> JellyfinAuth? {
        try? await JellyfinAsync.run {
            self.authenticate(
                base: base,
                username: username,
                password: password,
                deviceId: deviceId,
                completionHandler: $0
            )
        }
    }

    func browseAsync(
        base: String,
        token: String,
        userId: String,
        parentId: String?,
        startIndex: Int32,
        limit: Int32,
        order: JellyfinBrowseOrder
    ) async throws -> JellyfinItemPage {
        try await JellyfinAsync.run {
            self.browse(
                base: base,
                token: token,
                userId: userId,
                parentId: parentId,
                startIndex: startIndex,
                limit: limit,
                order: order,
                completionHandler: $0
            )
        }
    }

    func searchAsync(
        base: String,
        token: String,
        userId: String,
        term: String,
        filter: JellyfinSearchFilter,
        startIndex: Int32,
        limit: Int32
    ) async throws -> JellyfinItemPage {
        try await JellyfinAsync.run {
            self.search(
                base: base,
                token: token,
                userId: userId,
                term: term,
                filter: filter,
                startIndex: startIndex,
                limit: limit,
                completionHandler: $0
            )
        }
    }

    func itemMediaSourcesAsync(
        base: String,
        token: String,
        userId: String,
        itemId: String
    ) async throws -> [JellyfinMediaSource] {
        try await JellyfinAsync.run {
            self.itemMediaSources(
                base: base,
                token: token,
                userId: userId,
                itemId: itemId,
                completionHandler: $0
            )
        }
    }

    func sessionsAsync(base: String, token: String, userId: String) async -> [JellyfinSession] {
        (try? await JellyfinAsync.run {
            self.sessions(base: base, token: token, userId: userId, completionHandler: $0)
        }) ?? []
    }

    func playToSessionAsync(
        base: String,
        token: String,
        sessionId: String,
        itemIds: [String],
        startPositionTicks: Int64 = 0,
        mediaSourceId: String? = nil
    ) async throws -> Bool {
        let ok = try await JellyfinAsync.run {
            self.playToSession(
                base: base,
                token: token,
                sessionId: sessionId,
                itemIds: itemIds,
                startPositionTicks: startPositionTicks,
                mediaSourceId: mediaSourceId,
                completionHandler: $0
            )
        }
        return ok.boolValue
    }
}
