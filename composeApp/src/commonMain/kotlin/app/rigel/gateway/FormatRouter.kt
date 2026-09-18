package app.rigel.gateway

import app.rigel.bridge.ProbeResult
import app.rigel.output.OutputMediaProfile
import app.rigel.output.ReceiverCompatibilityMode
import app.rigel.settings.RouteOverride

enum class PlaybackRoute { DIRECT, REMUX, TRANSCODE }

sealed interface RouteDecision {
    data class Playable(
        val route: PlaybackRoute,
        val passthroughAudioCodecs: Set<String>,
        val detail: String,
    ) : RouteDecision

    data class Unsupported(val message: String) : RouteDecision
}

/** Pure source-plus-output delivery policy. */
object FormatRouter {
    private val directContainers = setOf("mp4", "mov")
    private val directVideo = setOf("h264")
    private val directAudio = setOf("aac", "mp3", "flac", "alac")
    private val remuxAudio = setOf("ac3", "eac3", "dts", "dca", "truehd", "opus", "vorbis")
    private val remuxContainers = setOf("matroska", "mkv", "webm", "avi", "mpegts", "asf")
    private val hlsContainers = setOf("m3u8", "hls")
    private val localPassthroughAudio = setOf("aac", "mp3", "flac", "alac")

    fun decide(
        probe: ProbeResult,
        profile: OutputMediaProfile,
        hasSelectedExternalSubtitle: Boolean,
        preference: RouteOverride = RouteOverride.AUTO,
        sourceIsRemotelyReachable: Boolean = true,
    ): RouteDecision {
        if (profile.detail == "This iPhone" || profile.mode == ReceiverCompatibilityMode.CONSERVATIVE &&
            profile.directSchemes.contains("file")
        ) {
            return localDecision(probe, preference, profile.detail)
        }

        val direct = directFeasible(probe, profile, sourceIsRemotelyReachable)
        val remux = remuxFeasible(probe, profile, hasSelectedExternalSubtitle)
        val transcode = transcodeFeasible(profile, probe, hasSelectedExternalSubtitle)

        val decision = when (preference) {
            RouteOverride.DIRECT -> direct ?: remux ?: transcode
            RouteOverride.ALWAYS_PROXY -> remux ?: transcode
            RouteOverride.AUTO -> direct ?: remux ?: transcode
        }
        return decision ?: RouteDecision.Unsupported(
            "Receiver cannot play this media and has no compatible HLS fallback: " + profile.detail,
        )
    }


    fun directPlayablePixelFormat(pixFmt: String?): Boolean = when (pixFmt?.lowercase()) {
        "yuv420p", "nv12" -> true
        else -> false
    }

    private fun localDecision(
        probe: ProbeResult,
        preference: RouteOverride,
        detail: String,
    ): RouteDecision {
        val route = localRoute(probe)
        val selected = when (preference) {
            RouteOverride.DIRECT -> PlaybackRoute.DIRECT
            RouteOverride.ALWAYS_PROXY -> if (route == PlaybackRoute.DIRECT) PlaybackRoute.REMUX else route
            RouteOverride.AUTO -> route
        }
        return RouteDecision.Playable(
            route = selected,
            passthroughAudioCodecs = localPassthroughAudio,
            detail = detailFor(selected, detail),
        )
    }

    private fun localRoute(probe: ProbeResult): PlaybackRoute {
        val container = probe.container.lowercase()
        val video = probe.videoCodec?.lowercase()
        val audio = probe.audioCodecs.map { it.lowercase() }.toSet()
        val hevcMain10 = video == "hevc" && probe.pixFmt?.lowercase() == "yuv420p10le"
        if (video in directVideo && !hevcMain10 && !directPlayablePixelFormat(probe.pixFmt)) {
            return PlaybackRoute.TRANSCODE
        }
        if (probe.isLive) return PlaybackRoute.DIRECT
        if (container in hlsContainers) return PlaybackRoute.DIRECT
        if (container in directContainers && video in directVideo && audio.all { it in directAudio }) {
            return PlaybackRoute.DIRECT
        }
        if (video in directVideo && (container in remuxContainers || audio.any { it in remuxAudio })) {
            return PlaybackRoute.REMUX
        }
        return PlaybackRoute.TRANSCODE
    }

    private fun directFeasible(
        probe: ProbeResult,
        profile: OutputMediaProfile,
        sourceReachable: Boolean,
    ): RouteDecision.Playable? {
        if (!sourceReachable) return null
        if (profile.mode != ReceiverCompatibilityMode.OPTIMISTIC_HTTP &&
            (probe.container.lowercase() !in profile.directContainers ||
                probe.videoCodec?.lowercase()?.let { it !in profile.directVideoCodecs } == true ||
                probe.audioCodecs.any { it.lowercase() !in profile.directAudioCodecs } ||
                probe.videoCodec != null && probe.pixFmt?.lowercase() !in profile.directPixelFormats ||
                !dimensionsFit(probe, profile))
        ) return null
        return RouteDecision.Playable(
            route = PlaybackRoute.DIRECT,
            passthroughAudioCodecs = probe.audioCodecs.map { it.lowercase() }.toSet(),
            detail = detailFor(PlaybackRoute.DIRECT, profile.detail),
        )
    }

    private fun remuxFeasible(
        probe: ProbeResult,
        profile: OutputMediaProfile,
        hasSelectedExternalSubtitle: Boolean,
    ): RouteDecision.Playable? {
        if (profile.hlsAudioCodecs.isEmpty()) return null
        if (hasSelectedExternalSubtitle && !profile.supportsHlsWebVtt) return null
        val video = probe.videoCodec?.lowercase()
        if (video != null && profile.hlsVideoCodecs.isEmpty()) return null
        if (video != null && (video !in profile.hlsVideoCodecs || !directPlayablePixelFormat(probe.pixFmt))) return null
        if (video != null && !dimensionsFit(probe, profile)) return null
        val passthrough = probe.audioCodecs.map { it.lowercase() }
            .filter { it in localPassthroughAudio && it in profile.hlsAudioCodecs }
            .toSet()
        return RouteDecision.Playable(
            route = PlaybackRoute.REMUX,
            passthroughAudioCodecs = passthrough,
            detail = detailFor(PlaybackRoute.REMUX, profile.detail),
        )
    }

    private fun transcodeFeasible(
        profile: OutputMediaProfile,
        probe: ProbeResult,
        hasSelectedExternalSubtitle: Boolean,
    ): RouteDecision.Playable? {
        val video = probe.videoCodec?.lowercase()
        if (profile.hlsAudioCodecs.contains("aac") &&
            (video == null || profile.hlsVideoCodecs.contains("h264")) &&
            (!hasSelectedExternalSubtitle || profile.supportsHlsWebVtt) &&
            (video == null || dimensionsFitTranscode(probe, profile))
        ) {
            return RouteDecision.Playable(
                route = PlaybackRoute.TRANSCODE,
                passthroughAudioCodecs = emptySet(),
                detail = detailFor(PlaybackRoute.TRANSCODE, profile.detail),
            )
        }
        return null
    }

    private fun dimensionsFit(probe: ProbeResult, profile: OutputMediaProfile): Boolean {
        if (probe.videoCodec == null) return true
        if (profile.maxWidth != null && (probe.width <= 0 || probe.width > profile.maxWidth)) return false
        if (profile.maxHeight != null && (probe.height <= 0 || probe.height > profile.maxHeight)) return false
        if (profile.maxH264Level != null && probe.videoCodec.equals("h264", ignoreCase = true)) {
            val level = probe.videoLevel ?: return false
            if (level > profile.maxH264Level) return false
        }
        if (profile.maxFrameRate != null && (probe.frameRate == null || probe.frameRate > profile.maxFrameRate)) return false
        return true
    }

    private fun dimensionsFitTranscode(probe: ProbeResult, profile: OutputMediaProfile): Boolean {
        if (probe.videoCodec == null) return true
        if (profile.maxFrameRate != null &&
            (probe.frameRate == null || probe.frameRate > profile.maxFrameRate)
        ) return false
        return profile.maxWidth == null || profile.maxHeight == null ||
            (probe.width <= 0 || probe.height <= 0 || profile.maxWidth >= 1920 && profile.maxHeight >= 1080)
    }
    private fun detailFor(route: PlaybackRoute, destination: String): String = when (route) {
        PlaybackRoute.DIRECT -> "Direct play on $destination"
        PlaybackRoute.REMUX -> "Remuxing for $destination"
        PlaybackRoute.TRANSCODE -> "Transcoding for $destination"
    }
}
