package app.rigel.bridge

import co.touchlab.kermit.Logger
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

/**
 * Suspend wrappers over the callback-style bridge interfaces.
 * Throws [IllegalStateException] when a bridge is not registered (Swift app startup missing).
 */
object Bridges {
    private const val TAG = "Bridges"

    private fun <T> requireBridge(name: String, value: T?): T =
        requireNotNull(value) { "$name bridge is not registered — call RigelBridgeFactory.register() at Swift app startup" }

    suspend fun ssdpSearch(searchTargets: List<String>, timeoutMs: Int): List<SsdpDevice> {
        val bridge = requireBridge("Discovery", RigelBridgeFactory.discovery)
        return suspendCancellableCoroutine { cont ->
            bridge.ssdpSearch(searchTargets, timeoutMs) { devices ->
                if (cont.isActive) cont.resume(devices)
            }
        }
    }

    suspend fun probe(url: String, headers: Map<String, String>): Pair<ProbeResult?, String?> {
        val bridge = requireBridge("Probe", RigelBridgeFactory.probe)
        return suspendCancellableCoroutine { cont ->
            bridge.probe(url, headers) { result, error ->
                if (cont.isActive) cont.resume(result to error)
            }
        }
    }

    suspend fun startHlsSession(
        sessionId: String,
        sourceUrl: String,
        headers: Map<String, String>,
        mode: String,
        onError: (String) -> Unit,
    ): Pair<String?, String?> {
        val bridge = requireBridge("Transcode", RigelBridgeFactory.transcode)
        return suspendCancellableCoroutine { cont ->
            bridge.startHlsSession(
                sessionId,
                sourceUrl,
                headers,
                mode,
                onReady = { path, error ->
                    if (cont.isActive) cont.resume(path to error)
                },
                onError = onError,
            )
        }
    }

    fun stopHlsSession(sessionId: String) {
        RigelBridgeFactory.transcode?.stopHlsSession(sessionId)
            ?: Logger.w(TAG) { "Transcode bridge not registered; stopHlsSession ignored" }
    }

    suspend fun startHttpServer(): Pair<Long, String?> {
        val bridge = requireBridge("HttpServer", RigelBridgeFactory.httpServer)
        return suspendCancellableCoroutine { cont ->
            bridge.start { port, error ->
                if (cont.isActive) cont.resume(port to error)
            }
        }
    }

    fun stopHttpServer() {
        RigelBridgeFactory.httpServer?.stop()
    }

    fun lanBaseUrl(): String? = RigelBridgeFactory.httpServer?.lanBaseUrl()
}
