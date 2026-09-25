package app.rigel.settings

import com.russhwolf.settings.Settings

/** JVM host used by shared tests; do not persist credentials in Settings. */
private class JvmInMemoryJellyfinTokenStore : JellyfinTokenStore {
    private var value: String? = null

    override fun read(): String? = value

    override fun write(value: String): Boolean {
        this.value = value
        return true
    }

    override fun clear(): Boolean {
        value = null
        return true
    }
}

internal actual fun createPlatformJellyfinTokenStore(): JellyfinTokenStore =
    JvmInMemoryJellyfinTokenStore()

internal actual fun createPlatformSettingsStore(): SettingsStore =
    SettingsStore(Settings(), createPlatformJellyfinTokenStore())
