package app.rigel.settings

import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverRegistry
import app.rigel.intake.UrlIntake
import com.russhwolf.settings.Settings

enum class RouteOverride { AUTO, DIRECT, ALWAYS_PROXY }
private const val MAX_LINK_HISTORY = 50

data class LinkHistoryEntry(val url: String, val title: String?)

/** The protected store used for the Jellyfin authentication token. */
interface JellyfinTokenStore {
    /** True when a successful write survives creation of a new token store. */
    val persistsAcrossInstances: Boolean
        get() = false
    fun read(): String?
    fun write(value: String): Boolean
    fun clear(): Boolean
}

private class CommonInMemoryJellyfinTokenStore : JellyfinTokenStore {
    override val persistsAcrossInstances = false
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

internal expect fun createPlatformJellyfinTokenStore(): JellyfinTokenStore
internal expect fun createPlatformSettingsStore(): SettingsStore

/** NSUserDefaults-backed preferences (multiplatform-settings). */
class SettingsStore(
    private val settings: Settings,
    private val jellyfinTokenStore: JellyfinTokenStore = CommonInMemoryJellyfinTokenStore(),
) {
    private val routeKey = "route_override"
    private val devicesKey = "manual_devices"
    private val jfServerKey = "jellyfin_server"
    private val jfTokenKey = "jellyfin_token"
    private val jfUserIdKey = "jellyfin_userid"
    private val jfUsernameKey = "jellyfin_username"
    private val linkHistoryKey = "link_history"

    init {
        migrateLegacyJellyfinToken()
        redactStoredHistory()
    }

    fun jellyfinServer(): String = settings.getString(jfServerKey, "")
    fun setJellyfinServer(v: String) = settings.putString(jfServerKey, v)

    fun jellyfinToken(): String = secureJellyfinToken() ?: settings.getString(jfTokenKey, "")

    fun setJellyfinToken(v: String): Boolean {
        if (v.isEmpty()) {
            // Keep the existing logical credential when secure deletion fails.
            val cleared = runCatching { jellyfinTokenStore.clear() }.getOrDefault(false)
            if (!cleared) return false
            settings.remove(jfTokenKey)
            return true
        }

        // Preserve the legacy value unless the replacement survives store recreation.
        val stored = runCatching { jellyfinTokenStore.write(v) }.getOrDefault(false)
        if (!stored) return false
        if (jellyfinTokenStore.persistsAcrossInstances) settings.remove(jfTokenKey)
        return true
    }

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

    fun linkHistory(): List<LinkHistoryEntry> {
        val entries = readHistoryEntries()
        persistSanitizedHistory(entries)
        return entries
    }

    fun addToLinkHistory(url: String, title: String?) {
        val sanitizedUrl = sanitizeHistoryUrl(url)
        if (sanitizedUrl.isEmpty()) return
        val sanitizedTitle = title
            ?.trim()
            ?.replace('|', ' ')
            ?.replace('\n', ' ')
            ?.takeIf { it.isNotBlank() }
        val newEntry = LinkHistoryEntry(sanitizedUrl, sanitizedTitle)
        val updated = (listOf(newEntry) + linkHistory().filterNot { it.url == sanitizedUrl })
            .take(MAX_LINK_HISTORY)
        settings.putString(
            linkHistoryKey,
            updated.joinToString("\n", transform = ::encodeHistoryRow),
        )
    }

    fun clearLinkHistory() {
        settings.putString(linkHistoryKey, "")
    }

    private fun secureJellyfinToken(): String? = runCatching {
        jellyfinTokenStore.read()?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    private fun migrateLegacyJellyfinToken() {
        if (!jellyfinTokenStore.persistsAcrossInstances) return
        val legacy = settings.getString(jfTokenKey, "")
        if (legacy.isEmpty()) return

        // A value already in protected storage is enough to retire the old
        // plaintext copy. Otherwise the copy remains until the write succeeds.
        if (secureJellyfinToken() != null || runCatching { jellyfinTokenStore.write(legacy) }.getOrDefault(false)) {
            settings.remove(jfTokenKey)
        }
    }

    private fun readHistoryEntries(): List<LinkHistoryEntry> =
        settings.getString(linkHistoryKey, "")
            .split('\n')
            .filter { it.isNotBlank() }
            .map(::parseHistoryRow)
            .map { it.copy(url = sanitizeHistoryUrl(it.url)) }
            .filter { it.url.isNotEmpty() }

    private fun redactStoredHistory() {
        val entries = readHistoryEntries()
        persistSanitizedHistory(entries)
    }

    private fun persistSanitizedHistory(entries: List<LinkHistoryEntry>) {
        val encoded = entries.joinToString("\n", transform = ::encodeHistoryRow)
        if (encoded != settings.getString(linkHistoryKey, "")) {
            settings.putString(linkHistoryKey, encoded)
        }
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
        entry.title?.let { it + "|" + entry.url }
            ?: if (entry.url.contains('|')) "|" + entry.url else entry.url

    private fun sanitizeHistoryUrl(url: String): String {
        val fragmentStart = url.indexOf('#')
        val fragment = if (fragmentStart >= 0) url.substring(fragmentStart) else ""
        val withoutFragment = if (fragmentStart >= 0) url.substring(0, fragmentStart) else url
        val queryStart = withoutFragment.indexOf('?')
        if (queryStart < 0) return url

        val path = withoutFragment.substring(0, queryStart)
        val kept = withoutFragment.substring(queryStart + 1)
            .split('&')
            .filterNot { isSensitiveHistoryQueryKey(it.substringBefore('=')) }
        return buildString {
            append(path)
            if (kept.isNotEmpty()) append('?').append(kept.joinToString("&"))
            append(fragment)
        }
    }

    private fun isSensitiveHistoryQueryKey(key: String): Boolean =
        UrlIntake.percentDecode(key)
            .trim()
            .lowercase()
            .replace("-", "")
            .replace("_", "") in SENSITIVE_HISTORY_QUERY_KEYS

    private companion object {
        val SENSITIVE_HISTORY_QUERY_KEYS = setOf(
            "apikey",
            "token",
            "accesstoken",
            "authtoken",
            "authorization",
            "bearer",
            "clientsecret",
            "password",
            "refreshtoken",
            "sessiontoken",
            "user_token".replace("_", ""),
            "xembytoken",
            "xmediabrowsertoken",
        )
    }
}
