package app.rigel

import app.rigel.devices.DevicesRepository
import app.rigel.player.PlayerController
import app.rigel.settings.SettingsStore
import app.rigel.source.jellyfin.JellyfinClient
import com.russhwolf.settings.Settings
import io.ktor.client.HttpClient

/**
 * Shared app singletons — pure Kotlin (no UI deps), so the same objects serve
 * any host UI (SwiftUI on iOS today, Compose/Android later).
 */
object RigelCore {
    val client: HttpClient = HttpClient()
    val settings: SettingsStore = SettingsStore(Settings())
    val controller: PlayerController = PlayerController(settings)
    val devices: DevicesRepository = DevicesRepository(client, settings)
    val jellyfin: JellyfinClient = JellyfinClient(client)
}
