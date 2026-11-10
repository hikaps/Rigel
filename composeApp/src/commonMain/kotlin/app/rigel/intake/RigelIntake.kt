package app.rigel.intake

import app.rigel.player.PlayerController

/**
 * Exposed to Swift (RigelIntake.shared.handle(url:)) for onOpenURL and
 * receive-mode pushes. URLs that arrive before a controller is attached are
 * queued and replayed on [attach].
 */
object RigelIntake {
    private var controller: PlayerController? = null
    private val pending = mutableListOf<Pair<String, String?>>()

    private fun current(): PlayerController = controller ?: app.rigel.RigelCore.controller

    fun attach(controller: PlayerController) {
        this.controller = controller
        val queued = pending.toList()
        pending.clear()
        for ((url, title) in queued) handle(url, title)
    }

    fun handle(url: String): Boolean = handle(url, null)

    fun handle(url: String, title: String?): Boolean {
        val ok = current().loadRaw(url, title)
        if (!ok && controller == null) {
            pending += url to title
            return true
        }
        return ok
    }

    /** Test-only: clear attach state and the pending queue. */
    internal fun resetForTest() {
        controller = null
        pending.clear()
    }
}
