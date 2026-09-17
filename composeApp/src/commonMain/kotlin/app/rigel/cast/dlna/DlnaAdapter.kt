package app.rigel.cast.dlna

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastResult
import app.rigel.cast.CastTarget
import app.rigel.cast.PreparedCastMedia
import app.rigel.cast.ReceiverAdapter
import app.rigel.output.CapabilitySource
import app.rigel.output.OutputMediaProfile
import app.rigel.output.OutputMediaProfiles
import app.rigel.output.ReceiverCompatibilityMode
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText

object DlnaAdapter : ReceiverAdapter {
    override val kind = "dlna"

    override val ssdpTargets = listOf("urn:schemas-upnp-org:device:MediaRenderer:1")

    override fun capabilities() = CastCapabilities(
        supportsSeek = true,
        supportsPosition = true,
        supportsPauseResume = true,
        supportsStop = true,
        supportsVolume = true,
        note = null,
    )

    override suspend fun mediaProfile(target: CastTarget, client: HttpClient): OutputMediaProfile {
        val device = (target as CastTarget.Dlna).device
        val sink = runCatching { DlnaRenderer(client).sinkProtocolInfo(device) }.getOrNull()
        return parseSinkProfile(target.name, sink)
    }

    private fun parseSinkProfile(name: String, sink: String?): OutputMediaProfile {
        if (sink.isNullOrBlank()) return OutputMediaProfiles.conservativeReceiver(name, "DLNA compatibility profile")
        val schemes = mutableSetOf<String>()
        val containers = mutableSetOf<String>()
        val videos = mutableSetOf<String>()
        val audios = mutableSetOf<String>()
        val hlsVideos = mutableSetOf<String>()
        val hlsAudios = mutableSetOf<String>()
        var hasAdvertisedHlsEntry = false
        sink.split(',').forEach { raw ->
            val fields = raw.trim().split(':')
            if (fields.size < 4) return@forEach
            val scheme = fields[0].lowercase()
            val mime = fields[2].lowercase()
            val profile = fields.drop(3).joinToString(":").lowercase()
            when (scheme) {
                "http-get" -> schemes += setOf("http", "https")
                else -> schemes += scheme
            }
            val isHls = mime.contains("mpegurl") || mime.contains("m3u8")
            if (isHls) hasAdvertisedHlsEntry = true
            val isVideo = mime.startsWith("video/")
            val isAudio = mime.startsWith("audio/")
            val h264 = profile.contains("avc") || profile.contains("h264")
            val aac = profile.contains("aac") ||
                (isAudio && (mime.contains("mp4") || mime.contains("aac")))
            if (mime.contains("mp4") || profile.contains("avc_mp4")) containers += "mp4"
            if (mime.contains("quicktime")) containers += "mov"
            if (isHls) containers += "m3u8"
            if (aac) {
                audios += "aac"
                if (isHls) hlsAudios += "aac"
            }
            if (isVideo && h264) {
                videos += "h264"
                if (isHls) hlsVideos += "h264"
            }
        }
        if (containers.isEmpty() && videos.isEmpty() && audios.isEmpty()) {
            return OutputMediaProfiles.conservativeReceiver(name, "DLNA compatibility profile")
        }
        val hlsFallback = !hasAdvertisedHlsEntry
        val conservative = OutputMediaProfiles.conservativeReceiver(name)
        return OutputMediaProfile(
            mode = ReceiverCompatibilityMode.DECLARED,
            source = CapabilitySource.ADVERTISED,
            directSchemes = schemes.ifEmpty { setOf("http") },
            directContainers = containers,
            directVideoCodecs = videos,
            directAudioCodecs = audios,
            directPixelFormats = setOf("yuv420p", "nv12"),
            hlsVideoCodecs = if (hlsFallback) conservative.hlsVideoCodecs else hlsVideos,
            hlsAudioCodecs = if (hlsFallback) conservative.hlsAudioCodecs else hlsAudios,
            supportsHlsWebVtt = if (hlsFallback) conservative.supportsHlsWebVtt else hlsVideos.isNotEmpty(),
            detail = name,
        )
    }

    override suspend fun cast(
        target: CastTarget,
        media: PreparedCastMedia,
        client: HttpClient,
    ): CastResult {
        val device = (target as CastTarget.Dlna).device
        val renderer = DlnaRenderer(client)
        val uriAccepted = renderer.setAvTransportUri(device, media)
        val playbackStarted = uriAccepted && renderer.play(device)
        return if (playbackStarted) CastResult.Sent("Sent to ${target.name}")
        else CastResult.Rejected("DLNA rejected the URL")
    }

    override suspend fun seek(
        target: CastTarget,
        positionMs: Long,
        durationMs: Long,
        client: HttpClient,
    ): Boolean = runCatching {
        DlnaRenderer(client).seek((target as CastTarget.Dlna).device, positionMs)
    }.getOrDefault(false)

    override suspend fun pause(target: CastTarget, client: HttpClient): Boolean = runCatching {
        DlnaRenderer(client).pause((target as CastTarget.Dlna).device)
    }.getOrDefault(false)

    override suspend fun resume(target: CastTarget, client: HttpClient): Boolean = runCatching {
        DlnaRenderer(client).resume((target as CastTarget.Dlna).device)
    }.getOrDefault(false)

    override suspend fun stop(target: CastTarget, client: HttpClient): Boolean = runCatching {
        DlnaRenderer(client).stop((target as CastTarget.Dlna).device)
    }.getOrDefault(false)

    override suspend fun volumeUp(target: CastTarget, client: HttpClient): Boolean = runCatching {
        DlnaRenderer(client).volumeUp((target as CastTarget.Dlna).device)
    }.getOrDefault(false)

    override suspend fun volumeDown(target: CastTarget, client: HttpClient): Boolean = runCatching {
        DlnaRenderer(client).volumeDown((target as CastTarget.Dlna).device)
    }.getOrDefault(false)

    override suspend fun toggleMute(target: CastTarget, client: HttpClient): Boolean = runCatching {
        DlnaRenderer(client).toggleMute((target as CastTarget.Dlna).device)
    }.getOrDefault(false)


    /**
     * Bug fix: live MediaRenderer SSDP responses now enrich into DLNA targets.
     * Previously only the literal "dlna" search target (manual rows) was handled.
     */
    override suspend fun fromSsdp(device: SsdpDevice, client: HttpClient): CastTarget? {
        if (!device.searchTarget.contains("MediaRenderer")) return null
        val xml = runCatching { client.get(device.location).bodyAsText() }.getOrNull()
            ?: return null
        val d = DlnaDeviceDescription.parse(device.usn, device.location, xml) ?: return null
        return CastTarget.Dlna(d)
    }

    override suspend fun fromRow(parts: List<String>, client: HttpClient): CastTarget? {
        val xml = runCatching { client.get(parts[2]).bodyAsText() }.getOrNull()
            ?: return null
        val d = DlnaDeviceDescription.parse(parts[1], parts[2], xml) ?: return null
        return CastTarget.Dlna(d)
    }

    override suspend fun probeManual(ip: String, client: HttpClient): CastTarget? {
        val location = "http://$ip/rootDesc.xml"
        val xml = runCatching { client.get(location).bodyAsText() }.getOrNull()
            ?: return null
        val usn = "manual-dlna-$ip"
        val device = DlnaDeviceDescription.parse(usn, location, xml) ?: return null
        return CastTarget.Dlna(device)
    }

    override fun rowFor(target: CastTarget): String {
        val d = (target as CastTarget.Dlna).device
        return "dlna|${d.usn}|${d.location}|${d.friendlyName}"
    }
}
