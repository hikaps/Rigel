import Foundation
import ComposeApp


/// Classifies completion-handler errors from the annotated Kotlin/Native
/// bridge. Kotlin exceptions surface as NSError (domain "KotlinException")
/// with the exported KotlinThrowable in userInfo["KotlinException"]; that
/// throwable does not conform to Swift Error, so cancellation is identified
/// by asking Kotlin.
enum JellyfinCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain.contains("CancellationException") { return true }
        guard let throwable = kotlinThrowable(error) else { return false }
        return JellyfinInterop.shared.isCancellation(throwable: throwable)
    }

    static func httpStatusCode(_ error: Error) -> Int? {
        guard let throwable = kotlinThrowable(error),
              let statusCode = JellyfinInterop.shared.httpStatusCode(throwable: throwable)
        else { return nil }
        return statusCode.intValue
    }

    private static func kotlinThrowable(_ error: Error) -> KotlinThrowable? {
        let ns = error as NSError
        let throwable = ns.kotlinException ?? ns.userInfo["KotlinException"]
        return throwable as? KotlinThrowable
    }
}
