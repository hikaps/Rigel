package app.rigel

import androidx.compose.ui.window.ComposeUIViewController
import app.rigel.ui.App
import platform.UIKit.UIViewController

/** SwiftUI entry: hosts the Compose UI (ContentView.swift → ComposeUIViewController). */
fun MainViewController(): UIViewController = ComposeUIViewController { App() }
