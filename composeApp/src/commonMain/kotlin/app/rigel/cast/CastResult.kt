package app.rigel.cast

/**
 * Outcome of a cast dispatch; [message] is the string the UI surfaces.
 * Only [Sent] commits the session as active.
 */
sealed class CastResult(val message: String) {
    /** Renderer accepted the media. */
    class Sent(message: String) : CastResult(message)

    /** Renderer refused the media or the attempt failed. */
    class Rejected(message: String) : CastResult(message)
}
