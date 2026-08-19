package app.rigel.player

import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.interop.UIKitView
import androidx.compose.ui.unit.dp
import kotlinx.cinterop.ExperimentalForeignApi
import platform.AVKit.AVRoutePickerView
import platform.CoreGraphics.CGRectMake

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun AirPlayRoutePickerButton(modifier: Modifier) {
    UIKitView(
        factory = {
            AVRoutePickerView().apply {
                setFrame(CGRectMake(0.0, 0.0, 44.0, 44.0))
            }
        },
        modifier = modifier.size(44.dp),
    )
}
