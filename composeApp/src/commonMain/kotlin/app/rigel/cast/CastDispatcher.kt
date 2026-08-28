package app.rigel.cast

import app.rigel.RigelCore
import app.rigel.bridge.Bridges
import app.rigel.player.PlayerPhase
import app.rigel.player.PlayerUiState
import io.ktor.client.HttpClient
import io.ktor.http.Url

/**
 * Send-flow entry point shared by every host UI. Resolves the URL a remote
 * renderer must fetch (a live local HLS proxy is only reachable over LAN,
 * never 127.0.0.1) and dispatches to the right adapter.
 */
object CastDispatcher {
    private val session = CastSession()

    fun capabilities(target: CastTarget): CastCapabilities = session.capabilities(target)

    fun activeTarget(): CastTarget? = session.activeTarget()

    fun clearActive() {
        session.clearActive()
        RigelCore.controller.setCastActive(false)
    }

    suspend fun seekActive(positionMs: Long, durationMs: Long): Boolean =
        seekActive(positionMs, durationMs, RigelCore.client)

    suspend fun seekActive(positionMs: Long, durationMs: Long, client: HttpClient): Boolean {
        val target = session.activeTarget() ?: return false
        return ReceiverRegistry.adapterFor(target).seek(
            target = target,
            positionMs = positionMs,
            durationMs = durationMs,
            client = client,
        )
    }


    fun remoteCastUrl(): String? = remoteCastUrl(RigelCore.controller.uiState.value)

    fun remoteCastUrl(state: PlayerUiState): String? {
        if (state.phase != PlayerPhase.PLAYING) return null
        state.proxyUrl?.let { proxy ->
            val lan = Bridges.lanBaseUrl() ?: return null
            // Re-host the proxy's relative path at the current LAN base. Parse
            // the URL properly: the proxy is LAN-formatted since the AirPlay
            // fix, so a 127.0.0.1 delimiter no longer exists (and would mangle
            // the path into //host:port/…).
            val path = Url(proxy).encodedPathAndQuery
            if (path.isNotEmpty()) return lan.trimEnd('/') + path
            return null
        }
        return state.sourceUrl
    }

    fun remoteCastTitle(): String = remoteCastTitle(RigelCore.controller.uiState.value)

    fun remoteCastTitle(state: PlayerUiState): String =
        state.filename
            ?: state.sourceUrl?.substringAfterLast('/')
            ?: "Stream"
    /** Returns a human-readable result/error string. */
    suspend fun cast(target: CastTarget, url: String, title: String): String =
        cast(target, url, title, RigelCore.client)

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
        client: HttpClient = RigelCore.client,
    ): String? {
        val attempt = session.beginAttemptFor(target) ?: return null
        val result = ReceiverRegistry.adapterFor(target).cast(target, url, title, client)
        if (result.startsWith("Sent to ") && session.commitActive(target, attempt)) {
            RigelCore.controller.setCastActive(true)
        }
        return result
    }

    /** Same dispatch with an injectable HTTP client (tests use a mock engine). */
    suspend fun cast(target: CastTarget, url: String, title: String, client: HttpClient): String {
        val attempt = session.beginAttempt()
        val result = ReceiverRegistry.adapterFor(target).cast(target, url, title, client)
        if (result.startsWith("Sent to ") && session.commitActive(target, attempt)) {
            RigelCore.controller.setCastActive(true)
        }
        return result
    }
}
