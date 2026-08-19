package app.rigel.gateway

import app.rigel.bridge.ProbeResult

/**
 * Decides how a source plays: AVPlayer directly, or via the local ffmpeg
 * HLS proxy (remux / transcode). Pure function — unit-tested against the
 * full decision table. Probe.swift normalizes container/codec names before
 * this runs (matroska, mp4, m3u8, h264, hevc, dts, ...).
 */
enum class PlaybackRoute { DIRECT, REMUX, TRANSCODE }

object FormatRouter {
    private val directContainers = setOf("mp4", "mov")
    private val directVideo = setOf("h264", "hevc")
    private val directAudio = setOf("aac", "mp3", "flac", "alac")
    private val remuxAudio = setOf("ac3", "eac3", "dts", "dca", "truehd", "opus", "vorbis")
    private val remuxContainers = setOf("matroska", "mkv", "webm", "avi", "mpegts", "asf")
    private val hlsContainers = setOf("m3u8", "hls")

    fun decide(probe: ProbeResult, hasExternalAssSubs: Boolean): PlaybackRoute {
        if (hasExternalAssSubs) return PlaybackRoute.TRANSCODE
        if (probe.isLive) return PlaybackRoute.DIRECT
        val container = probe.container.lowercase()
        if (container in hlsContainers) return PlaybackRoute.DIRECT
        val video = probe.videoCodec?.lowercase()
        val audio = probe.audioCodecs.map { it.lowercase() }.toSet()

        if (container in directContainers && video in directVideo &&
            audio.all { it in directAudio }
        ) return PlaybackRoute.DIRECT

        if (video in directVideo &&
            (container in remuxContainers || audio.any { it in remuxAudio })
        ) return PlaybackRoute.REMUX

        return PlaybackRoute.TRANSCODE
    }
}
