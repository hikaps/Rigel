package app.rigel.devices

import app.rigel.bridge.Bridges
import app.rigel.cast.CastTarget
import app.rigel.cast.dlna.DlnaDeviceDescription
import app.rigel.cast.dlna.DlnaRenderer
import app.rigel.cast.kodi.KodiDevice
import app.rigel.cast.kodi.KodiRenderer
import app.rigel.cast.roku.RokuRenderer
import app.rigel.settings.SettingsStore
import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText

data class DiscoveredDevice(
    val target: CastTarget,
    val via: String, // "ssdp" | "manual"
)

/**
 * SSDP discovery (DLNA MediaRenderer + roku:ecp) with manual-IP fallback.
 * Devices persisted as "kind|usn|location|name" rows in SettingsStore.
 */
class DevicesRepository(
    private val client: HttpClient,
    private val settings: SettingsStore,
) {
    private val tag = "DevicesRepository"
    private val kodiRenderer = KodiRenderer(client)

    private fun hostOf(location: String): String =
        location.removePrefix("http://").removePrefix("https://").substringBefore('/').substringBefore(':')

    suspend fun scan(timeoutMs: Long = 5000): List<DiscoveredDevice> {
        val found = mutableListOf<DiscoveredDevice>()
        val ssdp = runCatching {
            Bridges.ssdpSearch(
                listOf(
                    "urn:schemas-upnp-org:device:MediaRenderer:1",
                    "roku:ecp",
                ),
                timeoutMs.toInt(),
            )
        }.getOrDefault(emptyList())
        Logger.i(tag) { "SSDP found ${ssdp.size} devices" }

        for (device in ssdp) {
            if (device.searchTarget.contains("MediaRenderer")) {
                // Same host often runs Kodi (UPnP renderer + JSON-RPC on :8080).
                val kodiEndpoint = "http://${hostOf(device.location)}:8080"
                if (kodiRenderer.isKodi(kodiEndpoint)) {
                    found += DiscoveredDevice(
                        CastTarget.Kodi(KodiDevice("kodi-${device.usn}", kodiEndpoint, "Kodi")),
                        "ssdp",
                    )
                }
            }
            val target = enrich(device.usn, device.location, device.searchTarget) ?: continue
            found += DiscoveredDevice(target, "ssdp")
        }
        for (row in settings.manualDevices()) {
            val parts = row.split('|')
            if (parts.size < 4) continue
            val kind = parts[0]; val usn = parts[1]; val location = parts[2]; val name = parts[3]
            val target = when (kind) {
                "dlna" -> enrich(usn, location, "dlna") ?: continue
                "roku" -> enrich(usn, location, "roku:ecp") ?: continue
                "kodi" -> CastTarget.Kodi(KodiDevice(usn, location, name))
                else -> continue
            }
            if (found.none { it.target.name == target.name }) found += DiscoveredDevice(target, "manual")
        }
        return found
    }

    private suspend fun enrich(usn: String, location: String, searchTarget: String): CastTarget? =
        when {
            searchTarget.contains("roku:ecp") ->
                RokuRenderer(client).fetchDeviceInfo(usn, location)?.let { CastTarget.Roku(it) }
            searchTarget == "dlna" -> {
                val xml = runCatching { client.get(location).bodyAsText() }.getOrNull()
                xml?.let { DlnaDeviceDescription.parse(usn, location, it) }
                    ?.let { CastTarget.Dlna(it) }
            }
            else -> null
        }

    suspend fun addManualByIp(ip: String): CastTarget? {
        val trimmed = ip.trim().removePrefix("http://").removePrefix("https://").trimEnd('/')
        if (trimmed.isEmpty()) return null
        val kodiEndpoint = "http://$trimmed:8080"
        if (kodiRenderer.isKodi(kodiEndpoint)) {
            settings.addManualDevice("kodi|manual-kodi-$trimmed|$kodiEndpoint|Kodi")
            return CastTarget.Kodi(KodiDevice("manual-kodi-$trimmed", kodiEndpoint, "Kodi"))
        }
        val dlnaLocation = "http://$trimmed/rootDesc.xml"
        val dlnaProbe = runCatching { client.get(dlnaLocation).bodyAsText() }.getOrNull()
        if (dlnaProbe != null) {
            val usn = "manual-dlna-$trimmed"
            val device = DlnaDeviceDescription.parse(usn, dlnaLocation, dlnaProbe)
            if (device != null) {
                settings.addManualDevice("dlna|$usn|$dlnaLocation|${device.friendlyName}")
                return CastTarget.Dlna(device)
            }
        }
        val rokuLocation = "http://$trimmed:8060/"
        val rokuProbe = runCatching {
            RokuRenderer(client).fetchDeviceInfo("manual-roku-$trimmed", rokuLocation)
        }.getOrNull()
        if (rokuProbe != null) {
            settings.addManualDevice("roku|manual-roku-$trimmed|$rokuLocation|${rokuProbe.modelName ?: "Roku"}")
            return CastTarget.Roku(rokuProbe)
        }
        return null
    }

    fun removeManualDevice(target: CastTarget) {
        settings.removeManualDevice(target)
    }
}
