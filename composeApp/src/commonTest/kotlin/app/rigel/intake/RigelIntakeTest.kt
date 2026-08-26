package app.rigel.intake

import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.player.PlayerController
import app.rigel.player.PlayerPhase
import app.rigel.player.RigelIntake
import app.rigel.settings.LinkHistoryEntry
import app.rigel.settings.SettingsStore
import com.russhwolf.settings.MapSettings
import com.russhwolf.settings.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class RigelIntakeTest {

    private val dispatcher = StandardTestDispatcher()

    private fun controller() = PlayerController(SettingsStore(Settings()))

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        RigelIntake.resetForTest()
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun urlQueuedBeforeAttachIsReplayedOnAttach() {
        val c = controller()
        val ok = RigelIntake.handle("garbage-not-a-url")
        assertTrue(ok, "pre-attach intake should queue, not fail")

        RigelIntake.attach(c)
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase, "queued URL must be replayed to the controller")
    }

    @Test
    fun handleAfterAttachRoutesDirectlyAndDoesNotQueue() {
        val c = controller()
        RigelIntake.attach(c)

        assertFalse(RigelIntake.handle("garbage-not-a-url"))
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)

        // A fresh controller attached afterwards must not receive the old URL.
        val c2 = controller()
        RigelIntake.attach(c2)
        assertEquals(PlayerPhase.IDLE, c2.uiState.value.phase)
    }

    @Test
    fun attachReplaysMultipleQueuedUrls() {
        val c = controller()
        RigelIntake.handle("one")
        RigelIntake.handle("two")
        RigelIntake.attach(c)
        // Both replayed; the last one wins the final state.
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
    }

    @Test
    fun handleWithTitleRecordsTitleInHistory() = runTest(dispatcher.scheduler) {
        RigelBridgeFactory.register(
            discovery = null,
            probe = object : ProbeBridge {
                override fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, String?) -> Unit) {
                    onResult(null, "probe unavailable in intake test")
                }
            },
            transcode = null,
            httpServer = null,
        )
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val c = PlayerController(settings)
        RigelIntake.attach(c)

        assertTrue(RigelIntake.handle("http://h/v.mp4", "My Movie"))
        advanceUntilIdle()
        assertEquals(
            listOf(LinkHistoryEntry("http://h/v.mp4", "My Movie")),
            settings.linkHistory(),
        )
    }
}
