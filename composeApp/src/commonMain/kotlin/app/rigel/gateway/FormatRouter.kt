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
    // AVPlayer is accepting the HEVC audio track from Jellyfin but not
    // producing video on-device. Route HEVC through the HLS transcode path.
    private val directVideo = setOf("h264")
    private val directAudio = setOf("aac", "mp3", "flac", "alac")
    private val remuxAudio = setOf("ac3", "eac3", "dts", "dca", "truehd", "opus", "vorbis")
    private val remuxContainers = setOf("matroska", "mkv", "webm", "avi", "mpegts", "asf")
    private val hlsContainers = setOf("m3u8", "hls")

    fun decide(probe: ProbeResult, hasSelectedExternalSubtitle: Boolean): PlaybackRoute {
        val container = probe.container.lowercase()
        val video = probe.videoCodec?.lowercase()
        val audio = probe.audioCodecs.map { it.lowercase() }.toSet()

        // Apply the video safety gate before any subtitle or live/HLS policy.
        // A remux cannot make an unsupported pixel format decodable.
        val hevcMain10 = video == "hevc" && probe.pixFmt?.lowercase() == "yuv420p10le"
        if (video in directVideo && !hevcMain10 && !directPlayablePixelFormat(probe.pixFmt)) {
            return PlaybackRoute.TRANSCODE
        }

        // An app-rendered sidecar must become an HLS WebVTT rendition before
        // AirPlay. Video that can be stream-copied uses REMUX; all other video
        // goes through the existing full transcode path.
        if (hasSelectedExternalSubtitle && video != null) {
            return if (video == "h264" && directPlayablePixelFormat(probe.pixFmt)) {
                PlaybackRoute.REMUX
            } else {
                PlaybackRoute.TRANSCODE
            }
        }

        if (probe.isLive) return PlaybackRoute.DIRECT
        if (container in hlsContainers) return PlaybackRoute.DIRECT

        if (container in directContainers && video in directVideo &&
            audio.all { it in directAudio }
        ) return PlaybackRoute.DIRECT

        if (video in directVideo &&
            (container in remuxContainers || audio.any { it in remuxAudio })
        ) return PlaybackRoute.REMUX

        return PlaybackRoute.TRANSCODE
    }

    /**
     * AVPlayer hardware decode supports known 8-bit 4:2:0 formats. Unknown
     * or missing pix_fmt is unsafe: the demuxer may have omitted codecpar
     * format for Hi10P, 4:2:2, gray, RGB, or another unsupported surface.
     */
    fun directPlayablePixelFormat(pixFmt: String?): Boolean = when (pixFmt?.lowercase()) {
        "yuv420p", "nv12" -> true
        else -> false
    }
}
