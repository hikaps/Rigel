package app.rigel.intake

import app.rigel.player.PlayerController
import app.rigel.player.PlayerPhase
import app.rigel.player.RigelIntake
import app.rigel.settings.SettingsStore
import com.russhwolf.settings.Settings
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RigelIntakeTest {

    private fun controller() = PlayerController(SettingsStore(Settings()))

    @BeforeTest
    fun resetIntake() {
        RigelIntake.resetForTest()
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
}
