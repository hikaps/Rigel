package app.rigel.settings

import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverRegistry
import com.russhwolf.settings.Settings

enum class RouteOverride { AUTO, DIRECT, ALWAYS_PROXY }
private const val MAX_LINK_HISTORY = 50

data class LinkHistoryEntry(val url: String, val title: String?)

/** NSUserDefaults-backed preferences (multiplatform-settings). */
class SettingsStore(private val settings: Settings) {
    private val routeKey = "route_override"
    private val devicesKey = "manual_devices"
    private val jfServerKey = "jellyfin_server"
    private val jfTokenKey = "jellyfin_token"
    private val jfUserIdKey = "jellyfin_userid"
    private val jfUsernameKey = "jellyfin_username"
    private val linkHistoryKey = "link_history"

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
        val prefix = ReceiverRegistry.adapterFor(target).removalPrefix(target)
        settings.putString(
            devicesKey,
            manualDevices()
                .filterNot { it.startsWith(prefix) }
                .joinToString("\n"),
        )
    }
    fun linkHistory(): List<LinkHistoryEntry> =
        settings.getString(linkHistoryKey, "")
            .split('\n')
            .filter { it.isNotBlank() }
            .map(::parseHistoryRow)

    fun addToLinkHistory(url: String, title: String?) {
        val sanitizedTitle = title
            ?.trim()
            ?.replace('|', ' ')
            ?.replace('\n', ' ')
            ?.takeIf { it.isNotBlank() }
        val newEntry = LinkHistoryEntry(url, sanitizedTitle)
        val updated = (listOf(newEntry) + linkHistory().filterNot { it.url == url })
            .take(MAX_LINK_HISTORY)
        settings.putString(
            linkHistoryKey,
            updated.joinToString("\n", transform = ::encodeHistoryRow),
        )
    }

    fun clearLinkHistory() {
        settings.putString(linkHistoryKey, "")
    }

    private fun parseHistoryRow(row: String): LinkHistoryEntry {
        if (row.startsWith("|")) return LinkHistoryEntry(row.substring(1), null)
        val delimiter = row.indexOf('|')
        return if (delimiter > 0) {
            LinkHistoryEntry(
                url = row.substring(delimiter + 1),
                title = row.substring(0, delimiter),
            )
        } else {
            LinkHistoryEntry(url = row, title = null)
        }
    }

    private fun encodeHistoryRow(entry: LinkHistoryEntry): String =
        entry.title?.let { "$it|${entry.url}" }
            ?: if (entry.url.contains('|')) "|${entry.url}" else entry.url

}
