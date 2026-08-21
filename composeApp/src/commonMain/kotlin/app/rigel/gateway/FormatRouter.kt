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

        // Hi10P/12-bit H.264 and 4:2:2/4:4:4 sources break AVPlayer's decoder
        // regardless of container or audio. Remuxing cannot fix them (the
        // bitstream is copied verbatim), so they must fully transcode — the
        // proxy's scaler normalizes them to 8-bit NV12 for VideoToolbox.
        // Exception: HEVC Main10 (10-bit 4:2:0) hardware-decodes on every
        // device that runs this app, so it stays on the direct path.
        val hevcMain10 = video == "hevc" && probe.pixFmt?.lowercase() == "yuv420p10le"
        if (video in directVideo && !hevcMain10 && !directPlayablePixelFormat(probe.pixFmt)) {
            return PlaybackRoute.TRANSCODE
        }

        if (container in directContainers && video in directVideo &&
            audio.all { it in directAudio }
        ) return PlaybackRoute.DIRECT

        if (video in directVideo &&
            (container in remuxContainers || audio.any { it in remuxAudio })
        ) return PlaybackRoute.REMUX

        return PlaybackRoute.TRANSCODE
    }

    /**
     * AVPlayer hardware decode supports 8-bit 4:2:0 reliably; anything else
     * (4:2:2, 4:4:4, float, H.264 > 8-bit) fails at runtime. HEVC Main10 is
     * exempted in [decide]. Unknown formats stay eligible — probe may not
     * resolve pix_fmt.
     */
    fun directPlayablePixelFormat(pixFmt: String?): Boolean = when (pixFmt?.lowercase()) {
        null, "" -> true
        "yuv420p", "nv12" -> true
        else -> false
    }
}
