package app.rigel.output

import app.rigel.bridge.ProbeResult
import app.rigel.cast.CastTarget
import app.rigel.cast.RokuDevice
import app.rigel.gateway.FormatRouter
import app.rigel.gateway.PlaybackRoute
import app.rigel.gateway.RouteDecision
import app.rigel.settings.RouteOverride
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OutputRoutingTest {
    private fun probe(
        container: String,
        video: String? = "h264",
        audio: List<String> = listOf("aac"),
        width: Int = 1280,
        height: Int = 720,
        pixFmt: String? = "yuv420p",
        frameRate: Double? = 24.0,
    ) = ProbeResult(
        container = container,
        videoCodec = video,
        audioCodecs = audio,
        subtitleCodecs = emptyList(),
        durationMs = 60_000,
        isLive = false,
        pixFmt = pixFmt,
        width = width,
        height = height,
        videoLevel = 40,
        frameRate = frameRate
    )

    @Test
    fun conservativeReceiverDirectPlaysCompatibleMp4() {
        val profile = OutputMediaProfiles.conservativeReceiver("Roku")
        val decision = FormatRouter.decide(
            probe = probe("mp4"),
            profile = profile,
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.AUTO,
            sourceIsRemotelyReachable = true,
        )
        assertEquals(PlaybackRoute.DIRECT, (decision as RouteDecision.Playable).route)
    }

    @Test
    fun incompatibleVideoUsesHlsTranscode() {
        val profile = OutputMediaProfiles.conservativeReceiver("Chromecast")
        val decision = FormatRouter.decide(
            probe = probe("matroska", video = "hevc"),
            profile = profile,
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.AUTO,
            sourceIsRemotelyReachable = true,
        )
        assertEquals(PlaybackRoute.TRANSCODE, (decision as RouteDecision.Playable).route)
    }

    @Test
    fun loopbackAndFileSourcesCannotDirectDispatch() {
        val profile = OutputMediaProfiles.conservativeReceiver("TV")
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://127.0.0.1:8080/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://localhost./movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("file:///movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://127.1/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://2130706433/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://0/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://0.0/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://[::127.0.0.1]:8080/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://[::ffff:127.0.0.1]:8080/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://[0:0:0:0:0:ffff:127.0.0.1]:8080/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://[0:0:0:0:0:0:0:1]:8080/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://[::0.0.0.1]:8080/movie.mp4", profile))
        assertFalse(RemoteUrlPolicy.isReceiverFetchable("http://[::ffff:0.0.0.0]:8080/movie.mp4", profile))
        assertTrue(RemoteUrlPolicy.isReceiverFetchable("http://192.168.1.20/movie.mp4", profile))
        assertTrue(RemoteUrlPolicy.isReceiverFetchable("http://[::ffff:192.168.1.20]:8080/movie.mp4", profile))
        assertTrue(RemoteUrlPolicy.isReceiverFetchable("http://[::192.168.1.20]:8080/movie.mp4", profile))
    }

    @Test
    fun capabilityRepositoryCachesByTargetFingerprint() = kotlinx.coroutines.test.runTest {
        var now = 0L
        val repository = ReceiverCapabilityRepository(
            client = HttpClient(MockEngine { respond("") }),
            clockMillis = { now },
        )
        val target = CastTarget.Roku(RokuDevice("r1", "http://192.168.1.8:8060/", "Roku"))
        val first = repository.profileFor(target)
        now += 599_000L
        val second = repository.profileFor(target)
        assertEquals(first, second)
        now += 2_000L
        val third = repository.profileFor(target)
        assertEquals(first, third)
        repository.invalidate(target)
        assertEquals(first, repository.profileFor(target))

    }
    @Test
    fun airPlayTriesDirectBeforeProxyForUnknownReceiverCodec() {
        val airPlayDirect = FormatRouter.decide(
            probe = probe("webm", video = "vp9"),
            profile = OutputMediaProfiles.airPlay("Living Room"),
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.AUTO,
            sourceIsRemotelyReachable = true,
        ) as RouteDecision.Playable
        assertEquals(PlaybackRoute.DIRECT, airPlayDirect.route)

        val airPlayProxy = FormatRouter.decide(
            probe = probe("webm", video = "vp9"),
            profile = OutputMediaProfiles.airPlay("Living Room"),
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.ALWAYS_PROXY,
            sourceIsRemotelyReachable = true,
        ) as RouteDecision.Playable
        assertEquals(PlaybackRoute.TRANSCODE, airPlayProxy.route)

        val local = FormatRouter.decide(
            probe = probe("webm", video = "vp9"),
            profile = OutputMediaProfiles.local,
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.AUTO,
            sourceIsRemotelyReachable = true,
        ) as RouteDecision.Playable
        assertEquals(PlaybackRoute.TRANSCODE, local.route)
    }

    @Test
    fun audioOnlyReceiverCanUseAdvertisedAacHlsWithoutVideoCodec() {
        val profile = OutputMediaProfile(
            mode = ReceiverCompatibilityMode.DECLARED,
            source = CapabilitySource.ADVERTISED,
            directSchemes = setOf("http"),
            directContainers = setOf("mp4"),
            directVideoCodecs = emptySet(),
            directAudioCodecs = setOf("aac"),
            directPixelFormats = emptySet(),
            hlsVideoCodecs = emptySet(),
            hlsAudioCodecs = setOf("aac"),
            supportsHlsWebVtt = false,
            detail = "Audio receiver",
        )

        val decision = FormatRouter.decide(
            probe = probe("matroska", video = null),
            profile = profile,
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.AUTO,
            sourceIsRemotelyReachable = true,
        ) as RouteDecision.Playable

        assertEquals(PlaybackRoute.REMUX, decision.route)
    }

    @Test
    fun transcodeFallbackRejectsFrameRateAboveReceiverLimit() {
        val profile = OutputMediaProfiles.conservativeReceiver("TV").copy(maxFrameRate = 30.0)
        val decision = FormatRouter.decide(
            probe = probe("matroska", frameRate = 60.0),
            profile = profile,
            hasSelectedExternalSubtitle = false,
            preference = RouteOverride.AUTO,
            sourceIsRemotelyReachable = true,
        )

        assertTrue(decision is RouteDecision.Unsupported)
    }
}
