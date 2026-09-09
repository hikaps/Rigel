package app.rigel.devices

import app.rigel.bridge.Bridges
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverRegistry
import app.rigel.cast.ChromeDevice
import app.rigel.cast.chrome.ChromecastBridgeFactory
import app.rigel.settings.SettingsStore
import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
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

    suspend fun scan(timeoutMs: Long = 5000): List<DiscoveredDevice> = coroutineScope {
        val ssdpTargets = ReceiverRegistry.adapters.flatMap { it.ssdpTargets }.distinct()
        // SSDP and mDNS are independent search windows; run them concurrently
        // instead of paying both timeouts back to back.
        val ssdpSearch = async {
            runCatching { Bridges.ssdpSearch(ssdpTargets, timeoutMs.toInt()) }
                .getOrDefault(emptyList())
        }
        val mdnsSearch = async {
            if (ChromecastBridgeFactory.current != null) {
                runCatching { discoverChromecast(timeoutMs.toInt()) }.getOrDefault(emptyList())
            } else {
                emptyList()
            }
        }
        val ssdp = ssdpSearch.await()
        Logger.i(tag) { "SSDP found ${ssdp.size} devices" }

        // Per-response: first adapter that enriches wins (Kodi before DLNA).
        // Enrichment is concurrent, but results keep SSDP response order.
        val ssdpTargetsFound = ssdp.map { device ->
            async { ReceiverRegistry.adapters.firstNotNullOfOrNull { it.fromSsdp(device, client) } }
        }.awaitAll().filterNotNull()

        val found = mutableListOf<DiscoveredDevice>()
        ssdpTargetsFound.forEach { found += DiscoveredDevice(it, "ssdp") }
        mdnsSearch.await().forEach { device ->
            found += DiscoveredDevice(CastTarget.Chrome(device), "mdns")
        }

        // Persisted manual rows; fetched concurrently, kept in row order.
        val manualTargets = settings.manualDevices().map { row ->
            async {
                val parts = row.split('|')
                if (parts.size < 4) return@async null
                val adapter = ReceiverRegistry.adapters.firstOrNull { it.kind == parts[0] }
                    ?: return@async null
                adapter.fromRow(parts, client)
            }
        }.awaitAll().filterNotNull()
        manualTargets.forEach { target ->
            if (found.none { it.target.name == target.name }) found += DiscoveredDevice(target, "manual")
        }
        found
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
        // No cancel seam on ChromecastBridge: the browse runs to its
        // timeout; late results are dropped.
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
