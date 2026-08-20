package app.rigel

import co.touchlab.kermit.CommonWriter
import co.touchlab.kermit.Logger

internal actual fun setupLogging() {
    Logger.setLogWriters(CommonWriter())
}
