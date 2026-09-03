package app.rigel.devices

import app.rigel.bridge.Bridges
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverRegistry
import app.rigel.cast.ChromeDevice
import app.rigel.cast.chrome.ChromecastBridgeFactory
import app.rigel.settings.SettingsStore
import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

data class DiscoveredDevice(
    val target: CastTarget,
    val via: String, // "ssdp" | "mdns" | "manual"
)

/**
 * Registry-driven discovery (SSDP + mDNS) with manual-IP fallback.
 * Devices persisted as "kind|usn|location|name" rows in SettingsStore.
 */
class DevicesRepository(
    private val client: HttpClient,
    private val settings: SettingsStore,
) {
    private val tag = "DevicesRepository"

    suspend fun scan(timeoutMs: Long = 5000): List<DiscoveredDevice> {
        val found = mutableListOf<DiscoveredDevice>()
        val ssdpTargets = ReceiverRegistry.adapters.flatMap { it.ssdpTargets }.distinct()
        val ssdp = runCatching {
            Bridges.ssdpSearch(ssdpTargets, timeoutMs.toInt())
        }.getOrDefault(emptyList())
        Logger.i(tag) { "SSDP found ${ssdp.size} devices" }

        // Per-response: first adapter that enriches wins (Kodi before DLNA).
        for (device in ssdp) {
            val target = ReceiverRegistry.adapters
                .firstNotNullOfOrNull { it.fromSsdp(device, client) } ?: continue
            found += DiscoveredDevice(target, "ssdp")
        }
        if (ChromecastBridgeFactory.current != null) {
            runCatching { discoverChromecast(timeoutMs.toInt()) }
                .getOrDefault(emptyList())
                .forEach { device ->
                    found += DiscoveredDevice(CastTarget.Chrome(device), "mdns")
                }
        }

        // Persisted manual rows.
        for (row in settings.manualDevices()) {
            val parts = row.split('|')
            if (parts.size < 4) continue
            val adapter = ReceiverRegistry.adapters.firstOrNull { it.kind == parts[0] } ?: continue
            val target = adapter.fromRow(parts, client) ?: continue
            if (found.none { it.target.name == target.name }) found += DiscoveredDevice(target, "manual")
        }
        return found
    }

    suspend fun addManualByIp(ip: String): CastTarget? {
        val trimmed = ip.trim().removePrefix("http://").removePrefix("https://").trimEnd('/')
        if (trimmed.isEmpty()) return null
        for (adapter in ReceiverRegistry.adapters) {
            val target = adapter.probeManual(trimmed, client) ?: continue
            settings.addManualDevice(adapter.rowFor(target))
            return target
        }
        return null
    }

    fun removeManualDevice(target: CastTarget) {
        settings.removeManualDevice(target)
    }
    private suspend fun discoverChromecast(timeoutMs: Int): List<ChromeDevice> =
        suspendCancellableCoroutine { continuation ->
            val bridge = ChromecastBridgeFactory.current
            if (bridge == null) {
                continuation.resume(emptyList())
            } else {
                bridge.discover(timeoutMs) { devices ->
                    if (continuation.isActive) continuation.resume(devices)
                }
            }
        }

}
