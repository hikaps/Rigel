package app.rigel.gateway

import app.rigel.bridge.ProbeResult
import kotlin.test.Test
import kotlin.test.assertEquals

class FormatRouterTest {

    private fun probe(
        container: String,
        video: String?,
        audio: List<String> = emptyList(),
        isLive: Boolean = false,
    ) = ProbeResult(
        container = container,
        videoCodec = video,
        audioCodecs = audio,
        subtitleCodecs = emptyList(),
        durationMs = 60_000,
        isLive = isLive,
    )

    @Test
    fun liveStreamAlwaysDirect() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("m3u8", "h264", listOf("aac"), isLive = true), false))
    }

    @Test
    fun hlsContainerDirectEvenWhenNotLive() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("m3u8", "h264", listOf("aac")), false))
    }

    @Test
    fun mp4H264AacDirect() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("mp4", "h264", listOf("aac")), false))
    }

    @Test
    fun movHevcFlacDirect() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("mov", "hevc", listOf("flac")), false))
    }

    @Test
    fun mp4NoAudioDirect() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("mp4", "h264", emptyList()), false))
    }

    @Test
    fun mkvH264AacRemux() {
        assertEquals(PlaybackRoute.REMUX, FormatRouter.decide(probe("matroska", "h264", listOf("aac")), false))
    }

    @Test
    fun mp4H264DtsRemux() {
        assertEquals(PlaybackRoute.REMUX, FormatRouter.decide(probe("mp4", "h264", listOf("dts")), false))
    }

    @Test
    fun mkvH264DtsRemux() {
        assertEquals(PlaybackRoute.REMUX, FormatRouter.decide(probe("matroska", "h264", listOf("dts")), false))
    }

    @Test
    fun mkvH264Eac3Remux() {
        assertEquals(PlaybackRoute.REMUX, FormatRouter.decide(probe("matroska", "h264", listOf("eac3")), false))
    }

    @Test
    fun aviH264Remux() {
        assertEquals(PlaybackRoute.REMUX, FormatRouter.decide(probe("avi", "h264", listOf("aac")), false))
    }

    @Test
    fun vp9Transcode() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("webm", "vp9", listOf("opus")), false))
    }

    @Test
    fun av1Transcode() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mp4", "av1", listOf("aac")), false))
    }

    @Test
    fun mpeg4Transcode() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("avi", "mpeg4", listOf("mp3")), false))
    }

    @Test
    fun assSubtitleForcesTranscode() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mp4", "h264", listOf("aac")), true))
    }

    @Test
    fun hevcMkvWithOpusRemux() {
        assertEquals(PlaybackRoute.REMUX, FormatRouter.decide(probe("matroska", "hevc", listOf("opus")), false))
    }
}
