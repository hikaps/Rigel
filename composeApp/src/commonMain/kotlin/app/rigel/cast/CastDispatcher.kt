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

    /** Same dispatch with an injectable HTTP client (tests use a mock engine). */
    suspend fun cast(target: CastTarget, url: String, title: String, client: HttpClient): String =
        ReceiverRegistry.adapterFor(target).cast(target, url, title, client)
}
