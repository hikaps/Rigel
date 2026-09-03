package app.rigel.bridge

/**
 * Bridge interfaces implemented by the Swift side (iosApp/Bridge).
 * Mirrors the Nuvio PlayerBridge pattern: Kotlin interface + factory
 * registration from Swift at app startup.
 */

data class SsdpDevice(
    val usn: String,
    val location: String,
    val server: String?,
    val searchTarget: String,
)
data class SubtitleTrack(
    val url: String,
    val language: String? = null,
    val title: String? = null,
)


data class ProbeResult(
    val container: String,
    val videoCodec: String?,
    val audioCodecs: List<String>,
    val subtitleCodecs: List<String>,
    val durationMs: Long?,
    val isLive: Boolean,
    val pixFmt: String? = null,
    val width: Int = 0,
    val height: Int = 0,
)

interface DiscoveryBridge {
    fun ssdpSearch(searchTargets: List<String>, timeoutMs: Int, onResult: (List<SsdpDevice>) -> Unit)
}

interface ProbeBridge {
    fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, errorMsg: String?) -> Unit)
}

interface TranscodeBridge {
    fun startHlsSession(
        sessionId: String,
        sourceUrl: String,
        headers: Map<String, String>,
        mode: String,
        startOffsetMs: Long,
        subtitleTracks: List<SubtitleTrack>,
        onReady: (relativePlaylistPath: String?, errorMsg: String?) -> Unit,
        onError: (errorMsg: String) -> Unit,
    )

    fun stopHlsSession(sessionId: String)
}

interface HttpServerBridge {
    /** port == -1 on failure (non-null Long exports as scalar int64_t). */
    fun start(onStarted: (port: Long, errorMsg: String?) -> Unit)

    fun stop()

    fun lanBaseUrl(): String?
}

/** Registry mirroring NuvioPlayerBridgeFactory; Swift calls [register] at startup. */
object RigelBridgeFactory {
    private val discoverySlot = BridgeSlot<DiscoveryBridge>()
    private val probeSlot = BridgeSlot<ProbeBridge>()
    private val transcodeSlot = BridgeSlot<TranscodeBridge>()
    private val httpServerSlot = BridgeSlot<HttpServerBridge>()

    fun register(
        discovery: DiscoveryBridge?,
        probe: ProbeBridge?,
        transcode: TranscodeBridge?,
        httpServer: HttpServerBridge?,
    ) {
        discoverySlot.register(discovery)
        probeSlot.register(probe)
        transcodeSlot.register(transcode)
        httpServerSlot.register(httpServer)
    }

    val discovery: DiscoveryBridge? get() = discoverySlot.current
    val probe: ProbeBridge? get() = probeSlot.current
    val transcode: TranscodeBridge? get() = transcodeSlot.current
    val httpServer: HttpServerBridge? get() = httpServerSlot.current

    val isRegistered: Boolean
        get() = discoverySlot.isRegistered && probeSlot.isRegistered &&
            transcodeSlot.isRegistered && httpServerSlot.isRegistered
}

/** Common-facing access to the DLNA renderer receive mode (iosMain actual). */
expect object RendererBridgeAccess {
    /** Returns null on success, or an error message (e.g. missing multicast entitlement). */
    fun start(): String?

    fun stop()

    fun isRunning(): Boolean
}
