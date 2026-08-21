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
        pixFmt: String? = "yuv420p",
    ) = ProbeResult(
        container = container,
        videoCodec = video,
        audioCodecs = audio,
        subtitleCodecs = emptyList(),
        durationMs = 60_000,
        isLive = isLive,
        pixFmt = pixFmt,
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

    @Test
    fun hi10pMkvTranscodes() {
        // Remux copies the bitstream verbatim; AVPlayer still cannot decode
        // it. Only a full transcode normalizes 10-bit H.264.
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("matroska", "h264", listOf("aac"), pixFmt = "yuv420p10le"), false))
    }

    @Test
    fun hi10pMp4Transcodes() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mp4", "h264", listOf("aac"), pixFmt = "yuv420p10le"), false))
    }

    @Test
    fun hevcMain10StaysDirect() {
        // Hardware-decodes on every supported device.
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("mp4", "hevc", listOf("aac"), pixFmt = "yuv420p10le"), false))
    }

    @Test
    fun twelveBitTranscodes() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mp4", "h264", listOf("aac"), pixFmt = "yuv420p12le"), false))
    }

    @Test
    fun fourTwoTwoTranscodes() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mov", "h264", listOf("aac"), pixFmt = "yuv422p"), false))
    }

    @Test
    fun unknownPixFmtStaysDirect() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("mp4", "h264", listOf("aac"), pixFmt = null), false))
    }

    @Test
    fun nv12DirectPlayable() {
        assertEquals(PlaybackRoute.DIRECT, FormatRouter.decide(probe("mp4", "h264", listOf("aac"), pixFmt = "nv12"), false))
    }

    @Test
    fun nineBitTranscodes() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mp4", "hevc", listOf("aac"), pixFmt = "yuv420p9le"), false))
    }

    @Test
    fun sixteenBitTranscodes() {
        assertEquals(PlaybackRoute.TRANSCODE, FormatRouter.decide(probe("mp4", "hevc", listOf("aac"), pixFmt = "yuv420p16le"), false))
    }
}
