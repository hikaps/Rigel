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
        let throwable = ns.kotlinException ?? ns.userInfo["KotlinException"]
        guard let kotlinThrowable = throwable as? KotlinThrowable else {
            return false
        }
        return JellyfinInterop.shared.isCancellation(throwable: kotlinThrowable)
    }
}
