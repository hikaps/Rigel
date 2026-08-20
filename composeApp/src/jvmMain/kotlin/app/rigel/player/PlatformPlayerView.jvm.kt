package app.rigel.player

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** JVM actual: no video surface on the desktop test target. */
@Composable
actual fun PlatformPlayerView(
    sourceUrl: String,
    title: String?,
    sender: String?,
    onReady: () -> Unit,
    onError: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
) = Unit

@Composable
actual fun AirPlayRoutePickerButton(modifier: Modifier) = Unit
