package app.rigel.player

import app.rigel.bridge.HttpServerBridge
import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.TranscodeBridge
import app.rigel.settings.SettingsStore
import app.rigel.ui.AppState
import app.rigel.ui.Screen
import com.russhwolf.settings.MapSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
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

    private fun controller(): PlayerController {
        RigelBridgeFactory.register(
            discovery = null,
            probe = object : ProbeBridge {
                override fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, String?) -> Unit) {
                    onResult(ProbeResult("mp4", "h264", listOf("aac"), emptyList(), 60_000, isLive = false), null)
                }
            },
            transcode = object : TranscodeBridge {
                override fun startHlsSession(
                    sessionId: String,
                    sourceUrl: String,
                    headers: Map<String, String>,
                    mode: String,
                    onReady: (String?, String?) -> Unit,
                ) = onReady("hls/out.m3u8", null)

                override fun stopHlsSession(sessionId: String) = Unit
            },
            httpServer = object : HttpServerBridge {
                override fun start(onStarted: (Long, String?) -> Unit) = onStarted(8090, null)
                override fun stop() = Unit
                override fun lanBaseUrl(): String? = null
            },
        )
        return PlayerController(SettingsStore(MapSettings(mutableMapOf())))
    }

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        RigelIntake.resetForTests()
        AppState.screen.value = Screen.HOME
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
        AppState.screen.value = Screen.HOME
    }

    @Test
    fun urlIsQueuedUntilControllerAttaches() {
        val queued = RigelIntake.handle("http://h/v.mp4")
        assertTrue(queued)
        assertEquals(Screen.HOME, AppState.screen.value)

        val controller = controller()
        RigelIntake.attach(controller)
        // Queued URL replayed into the controller and routed to the player screen.
        assertEquals(PlayerPhase.PROBING, controller.uiState.value.phase)
        assertEquals(Screen.PLAYER, AppState.screen.value)
    }

    @Test
    fun handleAfterAttachLoadsAndSwitchesScreen() {
        val controller = controller()
        RigelIntake.attach(controller)

        val accepted = AppState.onIntake("http://h/v.mp4")
        assertTrue(accepted)
        assertEquals(PlayerPhase.PROBING, controller.uiState.value.phase)
        assertEquals(Screen.PLAYER, AppState.screen.value)
    }

    @Test
    fun invalidUrlRejectedWithoutScreenChange() {
        val controller = controller()
        RigelIntake.attach(controller)

        val accepted = RigelIntake.handle("not a url")
        assertFalse(accepted)
        assertEquals(Screen.HOME, AppState.screen.value)
    }
}
