package app.rigel.cast

import app.rigel.bridge.Bridges
import io.ktor.client.HttpClient
import io.ktor.http.Url

/**
 * Read/write access the cast layer needs into playback orchestration.
 * [app.rigel.player.PlayerController] implements it; RigelCore wires the pair
 * at startup so the cast package never depends on the player layer.
 */
interface CastPlaybackPort {
    fun setCastActive(active: Boolean)

    fun remoteCastUrl(): String?

    fun remoteCastTitle(): String
}

/**
 * Send-flow entry point shared by every host UI. Resolves the URL a remote
 * renderer must fetch (a live local HLS proxy is only reachable over LAN,
 * never 127.0.0.1) and dispatches to the right adapter.
 */
object CastDispatcher {
    private val session = CastSession()

    /** Composition-root wiring (RigelCore); tests install fakes and clear in teardown. */
    internal var playbackPort: CastPlaybackPort? = null
    internal var defaultClient: HttpClient? = null

    /** Wire the production (or test) playback port and default HTTP client. */
    fun install(playbackPort: CastPlaybackPort?, client: HttpClient?) {
        this.playbackPort = playbackPort
        this.defaultClient = client
    }

    fun capabilities(target: CastTarget): CastCapabilities = session.capabilities(target)

    fun activeTarget(): CastTarget? = session.activeTarget()

    fun clearActive() {
        session.clearActive()
        playbackPort?.setCastActive(false)
    }

    suspend fun seekActive(positionMs: Long, durationMs: Long): Boolean =
        seekActive(positionMs, durationMs, requireClient())

    suspend fun seekActive(positionMs: Long, durationMs: Long, client: HttpClient): Boolean {
        val target = session.activeTarget() ?: return false
        return ReceiverRegistry.adapterFor(target).seek(
            target = target,
            positionMs = positionMs,
            durationMs = durationMs,
            client = client,
        )
    }


    fun remoteCastUrl(): String? = playbackPort?.remoteCastUrl()

    fun remoteCastUrl(isPlaying: Boolean, proxyUrl: String?, sourceUrl: String?): String? {
        if (!isPlaying) return null
        proxyUrl?.let { proxy ->
            val lan = Bridges.lanBaseUrl() ?: return null
            // Re-host the proxy's relative path at the current LAN base. Parse
            // the URL properly: the proxy is LAN-formatted since the AirPlay
            // fix, so a 127.0.0.1 delimiter no longer exists (and would mangle
            // the path into //host:port/…).
            val path = Url(proxy).encodedPathAndQuery
            if (path.isNotEmpty()) return lan.trimEnd('/') + path
            return null
        }
        return sourceUrl
    }

    fun remoteCastTitle(): String = playbackPort?.remoteCastTitle() ?: "Stream"

    fun remoteCastTitle(filename: String?, sourceUrl: String?): String =
        filename
            ?: sourceUrl?.substringAfterLast('/')
            ?: "Stream"

    /** Dispatch with the installed default client. */
    suspend fun cast(target: CastTarget, url: String, title: String): CastResult =
        cast(target, url, title, requireClient())

    /**
     * Re-send media only while [target] remains the active receiver. The
     * commit token is minted before dispatch, so a clearActive() during the
     * adapter call voids the commit instead of resurrecting the session.
     * Returns null immediately when [target] is no longer active.
     */
    suspend fun recastIfActive(
        target: CastTarget,
        url: String,
        title: String,
        client: HttpClient = requireClient(),
    ): CastResult? {
        val attempt = session.beginAttemptFor(target) ?: return null
        val result = ReceiverRegistry.adapterFor(target).cast(target, url, title, client)
        if (result is CastResult.Sent && session.commitActive(target, attempt)) {
            playbackPort?.setCastActive(true)
        }
        return result
    }

    /** Same dispatch with an injectable HTTP client (tests use a mock engine). */
    suspend fun cast(target: CastTarget, url: String, title: String, client: HttpClient): CastResult {
        val attempt = session.beginAttempt()
        val result = ReceiverRegistry.adapterFor(target).cast(target, url, title, client)
        if (result is CastResult.Sent && session.commitActive(target, attempt)) {
            playbackPort?.setCastActive(true)
        }
        return result
    }

    private fun requireClient(): HttpClient =
        defaultClient
            ?: throw IllegalStateException("CastDispatcher client not installed — call install() at app startup")
}
