package app.rigel.cast

import app.rigel.bridge.Bridges
import app.rigel.output.OutputMediaProfiles
import app.rigel.output.RemoteUrlPolicy
import io.ktor.client.HttpClient
import io.ktor.http.Url
interface CastPlaybackPort {
    fun setCastActive(active: Boolean)
    fun remoteCastUrl(): String?
    fun remoteCastTitle(): String
    fun stopPlayback()
}

interface CastDispatching {
    fun activeTarget(): CastTarget?
    suspend fun cast(target: CastTarget, media: PreparedCastMedia): CastResult
    suspend fun recastIfActive(target: CastTarget, media: PreparedCastMedia): CastResult?
    suspend fun seekActive(positionMs: Long, durationMs: Long): Boolean
    fun detachActive(): CastTarget?
    suspend fun stopDetached(target: CastTarget): Boolean
}

/** Transport/session owner. Playback planning remains in PlayerController. */
object CastDispatcher : CastDispatching {
    private val session = CastSession()

    internal var playbackPort: CastPlaybackPort? = null
    internal var defaultClient: HttpClient? = null

    fun install(playbackPort: CastPlaybackPort?, client: HttpClient?) {
        this.playbackPort = playbackPort
        this.defaultClient = client
    }

    fun capabilities(target: CastTarget): CastCapabilities = session.capabilities(target)

    override fun activeTarget(): CastTarget? = session.activeTarget()

    override fun detachActive(): CastTarget? {
        val previous = session.detachActive()
        if (previous != null) playbackPort?.setCastActive(false)
        return previous
    }

    fun clearActive() {
        detachActive()
    }

    override suspend fun seekActive(positionMs: Long, durationMs: Long): Boolean =
        seekActive(positionMs, durationMs, requireClient())

    suspend fun seekActive(positionMs: Long, durationMs: Long, client: HttpClient): Boolean {
        val target = session.activeTarget() ?: return false
        return ReceiverRegistry.adapterFor(target).seek(target, positionMs, durationMs, client)
    }

    suspend fun pauseActive(): Boolean = pauseActive(requireClient())

    suspend fun pauseActive(client: HttpClient): Boolean =
        controlActive(client) { adapter, target -> adapter.pause(target, client) }

    suspend fun resumeActive(): Boolean = resumeActive(requireClient())

    suspend fun resumeActive(client: HttpClient): Boolean =
        controlActive(client) { adapter, target -> adapter.resume(target, client) }

    suspend fun volumeUpActive(): Boolean = volumeUpActive(requireClient())

    suspend fun volumeUpActive(client: HttpClient): Boolean =
        controlActive(client) { adapter, target -> adapter.volumeUp(target, client) }

    suspend fun volumeDownActive(): Boolean = volumeDownActive(requireClient())

    suspend fun volumeDownActive(client: HttpClient): Boolean =
        controlActive(client) { adapter, target -> adapter.volumeDown(target, client) }

    suspend fun toggleMuteActive(): Boolean = toggleMuteActive(requireClient())

    suspend fun toggleMuteActive(client: HttpClient): Boolean =
        controlActive(client) { adapter, target -> adapter.toggleMute(target, client) }

    suspend fun stopActive(): Boolean = stopActiveThroughPlayback(null)

    suspend fun stopActive(client: HttpClient): Boolean = stopActiveThroughPlayback(client)

    private suspend fun stopActiveThroughPlayback(client: HttpClient?): Boolean {
        if (activeTarget() == null) return false
        playbackPort?.stopPlayback()
        if (activeTarget() == null) return true
        val target = detachActive() ?: return false
        return if (client == null) stopDetached(target) else stopDetached(target, client)
    }

    override suspend fun stopDetached(target: CastTarget): Boolean =
        stopDetached(target, requireClient())

    suspend fun stopDetached(target: CastTarget, client: HttpClient): Boolean = runCatching {
        ReceiverRegistry.adapterFor(target).stop(target, client)
    }.getOrDefault(false)

    private suspend fun controlActive(
        client: HttpClient,
        op: suspend (ReceiverAdapter, CastTarget) -> Boolean,
    ): Boolean {
        val target = session.activeTarget() ?: return false
        return op(ReceiverRegistry.adapterFor(target), target)
    }

    override suspend fun cast(target: CastTarget, media: PreparedCastMedia): CastResult =
        cast(target, media, requireClient())

    suspend fun cast(target: CastTarget, media: PreparedCastMedia, client: HttpClient): CastResult {
        if (media.origin == CastMediaOrigin.SOURCE &&
            !RemoteUrlPolicy.isReceiverFetchable(media.url, OutputMediaProfiles.optimisticHttp(target.name))
        ) {
            return CastResult.Rejected("Receiver cannot fetch the source URL")
        }
        val attempt = session.beginAttempt()
        val result = ReceiverRegistry.adapterFor(target).cast(target, media, client)
        if (result is CastResult.Sent && session.commitActive(target, attempt)) {
            playbackPort?.setCastActive(true)
        }
        return result
    }

    override suspend fun recastIfActive(target: CastTarget, media: PreparedCastMedia): CastResult? =
        recastIfActive(target, media, requireClient())

    suspend fun recastIfActive(
        target: CastTarget,
        media: PreparedCastMedia,
        client: HttpClient,
    ): CastResult? {
        if (media.origin == CastMediaOrigin.SOURCE &&
            !RemoteUrlPolicy.isReceiverFetchable(media.url, OutputMediaProfiles.optimisticHttp(target.name))
        ) return CastResult.Rejected("Receiver cannot fetch the source URL")
        val attempt = session.beginAttemptFor(target) ?: return null
        val result = ReceiverRegistry.adapterFor(target).cast(target, media, client)
        if (result is CastResult.Sent && session.commitActive(target, attempt)) {
            playbackPort?.setCastActive(true)
        }
        return result
    }

    /** Compatibility wrapper until host UI switches to PreparedCastMedia. */
    suspend fun cast(target: CastTarget, url: String, title: String): CastResult =
        cast(target, prepared(url, title), requireClient())

    suspend fun cast(target: CastTarget, url: String, title: String, client: HttpClient): CastResult =
        cast(target, prepared(url, title), client)
    suspend fun recastIfActive(target: CastTarget, url: String, title: String, client: HttpClient = requireClient()): CastResult? =
        recastIfActive(target, prepared(url, title), client)

    fun remoteCastUrl(): String? = playbackPort?.remoteCastUrl()

    fun remoteCastUrl(isPlaying: Boolean, proxyUrl: String?, sourceUrl: String?): String? {
        if (!isPlaying) return null
        if (proxyUrl != null) {
            val lan = Bridges.lanBaseUrl() ?: return null
            val path = Url(proxyUrl).encodedPathAndQuery
            return if (path.isNotEmpty()) lan.trimEnd('/') + path else null
        }
        return sourceUrl
    }

    fun remoteCastTitle(): String = playbackPort?.remoteCastTitle() ?: "Stream"

    fun remoteCastTitle(filename: String?, sourceUrl: String?): String =
        filename ?: sourceUrl?.substringAfterLast("/") ?: "Stream"

    private fun prepared(url: String, title: String): PreparedCastMedia = PreparedCastMedia(
        url = url,
        title = title,
        contentType = contentTypeFor(url),
        container = url.substringBefore('?').substringAfterLast('.').lowercase(),
        kind = if (url.substringBefore('?').substringAfterLast('.').lowercase() in setOf("mp3", "m4a", "aac", "flac")) {
            CastMediaKind.AUDIO
        } else CastMediaKind.VIDEO,
        isLive = false,
        origin = CastMediaOrigin.SOURCE,
    )

    private fun contentTypeFor(url: String): String = when (
        url.substringBefore('?').substringAfterLast('.').lowercase()
    ) {
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "m3u8" -> "application/vnd.apple.mpegurl"
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "aac" -> "audio/aac"
        "flac" -> "audio/flac"
        else -> "video/mp4"
    }

    private fun requireClient(): HttpClient =
        defaultClient ?: throw IllegalStateException("CastDispatcher client not installed — call install() at app startup")
}
