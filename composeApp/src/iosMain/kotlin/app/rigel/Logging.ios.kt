package app.rigel

import co.touchlab.kermit.Logger
import co.touchlab.kermit.NSLogWriter

internal actual fun setupLogging() {
    // Default Kermit writer on Apple is os_log-based but invisible in syslog
    // relays; NSLogWriter makes every Kotlin-side log (intake/probe/route/proxy)
    // visible in device syslog for on-device debugging.
    Logger.setLogWriters(NSLogWriter())
    Logger.i("Rigel") { "app start" }
}
