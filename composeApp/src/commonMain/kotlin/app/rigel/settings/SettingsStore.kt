package app.rigel.settings

import app.rigel.cast.CastTarget
import com.russhwolf.settings.Settings

enum class RouteOverride { AUTO, DIRECT, ALWAYS_PROXY }
enum class TranscodeCap(val label: String) { P720("720p"), P1080("1080p") }

/** NSUserDefaults-backed preferences (multiplatform-settings). */
class SettingsStore(private val settings: Settings) {
    private val routeKey = "route_override"
    private val capKey = "transcode_cap"
    private val devicesKey = "manual_devices"
    private val jfServerKey = "jellyfin_server"
    private val jfTokenKey = "jellyfin_token"
    private val jfUserIdKey = "jellyfin_userid"
    private val jfUsernameKey = "jellyfin_username"

    fun jellyfinServer(): String = settings.getString(jfServerKey, "")
    fun setJellyfinServer(v: String) = settings.putString(jfServerKey, v)
    fun jellyfinToken(): String = settings.getString(jfTokenKey, "")
    fun setJellyfinToken(v: String) = settings.putString(jfTokenKey, v)
    fun jellyfinUserId(): String = settings.getString(jfUserIdKey, "")
    fun setJellyfinUserId(v: String) = settings.putString(jfUserIdKey, v)
    fun jellyfinUsername(): String = settings.getString(jfUsernameKey, "")
    fun setJellyfinUsername(v: String) = settings.putString(jfUsernameKey, v)

    fun routeOverride(): RouteOverride = when (settings.getString(routeKey, "AUTO")) {
        "DIRECT" -> RouteOverride.DIRECT
        "ALWAYS_PROXY" -> RouteOverride.ALWAYS_PROXY
        else -> RouteOverride.AUTO
    }

    fun setRouteOverride(value: RouteOverride) = settings.putString(routeKey, value.name)

    fun transcodeCap(): TranscodeCap =
        if (settings.getString(capKey, "1080p") == "720p") TranscodeCap.P720 else TranscodeCap.P1080

    fun setTranscodeCap(value: TranscodeCap) = settings.putString(capKey, value.label)

    fun manualDevices(): List<String> = settings.getString(devicesKey, "").split('\n').filter { it.isNotBlank() }

    fun addManualDevice(row: String) {
        val current = manualDevices().toMutableList()
        // Dedupe by device location (kind|usn|location|name), not by kind:
        // two manual devices of the same type (e.g. two Kodi boxes) must both survive.
        val location = row.split('|').getOrNull(2)
        if (location != null && current.none { it.split('|').getOrNull(2) == location }) current += row
        settings.putString(devicesKey, current.joinToString("\n"))
    }

    fun removeManualDevice(target: CastTarget) {
        val (kind, usn) = when (target) {
            is CastTarget.Dlna -> "dlna" to target.device.usn
            is CastTarget.Roku -> "roku" to target.device.usn
            is CastTarget.Kodi -> "kodi" to target.device.usn
            is CastTarget.JellyfinSessionTarget -> "jellyfin" to ""
        }
        val prefix = "$kind|$usn|"
        settings.putString(
            devicesKey,
            manualDevices()
                .filterNot { it.startsWith(prefix) }
                .joinToString("\n"),
        )
    }
}
