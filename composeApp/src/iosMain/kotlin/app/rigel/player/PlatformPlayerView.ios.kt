package app.rigel.player

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.interop.UIKitViewController
import app.rigel.bridge.NativePlayerBridge
import app.rigel.bridge.PlayerBridgeFactory
import app.rigel.bridge.PlayerEvents
import kotlinx.cinterop.ExperimentalForeignApi

/**
 * Hosts the Swift AVPlayerViewController via the native bridge (Nuvio pattern).
 * The native player view owns its own top bar (title, sender, AirPlay button) —
 * embedded AVPlayerViewController's view covers the surface, so Compose-drawn
 * overlays would sit underneath it.
 */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun PlatformPlayerView(
    sourceUrl: String,
    title: String?,
    sender: String?,
    onReady: () -> Unit,
    onError: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
) {
    val bridge: NativePlayerBridge? = remember { PlayerBridgeFactory.create() }
    if (bridge == null) {
        Text("Player bridge not registered")
        return
    }
    val events = remember {
        object : PlayerEvents {
            override fun onReady() = onReady()
            override fun onError(message: String) = onError(message)
            override fun onBack() = onBack()
        }
    }
    val controller = remember { bridge.createPlayerViewController(events) }

    LaunchedEffect(sourceUrl) { bridge.load(sourceUrl, title, sender) }
    DisposableEffect(Unit) {
        onDispose { bridge.stop() }
    }

    UIKitViewController(
        factory = { controller },
        modifier = modifier,
    )
}
