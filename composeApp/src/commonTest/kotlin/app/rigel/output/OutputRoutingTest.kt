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
        video: String = "h264",
        audio: List<String> = listOf("aac"),
        width: Int = 1280,
        height: Int = 720,
        pixFmt: String? = "yuv420p",
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
        frameRate = 24.0
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
        assertTrue(RemoteUrlPolicy.isReceiverFetchable("http://192.168.1.20/movie.mp4", profile))
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
}
