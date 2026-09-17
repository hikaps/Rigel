package app.rigel.bridge

import app.rigel.RigelCore
import app.rigel.cast.CastTarget
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import app.rigel.output.OutputSelectionState

/** Explicit Swift interop for the app-session playback destination preference. */
object SwiftOutputSelection {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun snapshot(): OutputSelectionState = RigelCore.outputSelection.snapshot()

    fun observe(onChange: (OutputSelectionState) -> Unit): Job =
        scope.launch { RigelCore.outputSelection.state.collect { onChange(it) } }

    fun selectLocal() = RigelCore.outputSelection.selectLocal()

    fun selectAirPlay(routeId: String, name: String) =
        RigelCore.outputSelection.selectAirPlay(routeId, name)

    fun selectReceiver(target: CastTarget) =
        RigelCore.outputSelection.selectReceiver(target)

    fun clearJellyfinServer(serverBase: String) =
        RigelCore.outputSelection.clearJellyfinServer(serverBase)
    fun replaceIfSameIdentity(target: CastTarget): Boolean =
        RigelCore.outputSelection.replaceIfSameIdentity(target)
}
