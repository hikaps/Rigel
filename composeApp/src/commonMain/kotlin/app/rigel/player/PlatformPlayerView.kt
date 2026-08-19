package app.rigel.player

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/** Hosts the platform video surface (AVPlayerViewController on iOS). */
@Composable
expect fun PlatformPlayerView(
    sourceUrl: String,
    title: String?,
    sender: String?,
    onReady: () -> Unit,
    onError: (String) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
)

/** System AirPlay route button (AVRoutePickerView on iOS). */
@Composable
expect fun AirPlayRoutePickerButton(modifier: Modifier = Modifier)
