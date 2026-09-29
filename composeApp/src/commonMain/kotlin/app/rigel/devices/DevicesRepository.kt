package app.rigel.devices
import co.touchlab.kermit.Logger
import app.rigel.bridge.Bridges
import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverRegistry
import app.rigel.cast.ChromeDevice
import app.rigel.cast.chrome.ChromecastBridgeFactory
import app.rigel.settings.SettingsStore
import app.rigel.source.jellyfin.JellyfinClient
import app.rigel.output.canonicalIpAddress
import io.ktor.client.HttpClient
import io.ktor.http.Url
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume


data class DiscoveredDevice(
    val target: CastTarget,
    val via: String, // "ssdp" | "mdns" | "manual"
)

private sealed class DiscoveryResult(
    val index: Int,
    val target: CastTarget,
    val via: String,
    val sourceOrder: Int,
) {
    class Ssdp(index: Int, target: CastTarget) : DiscoveryResult(index, target, "ssdp", 0)
    class Mdns(index: Int, target: CastTarget) : DiscoveryResult(index, target, "mdns", 1)
    class Manual(index: Int, target: CastTarget) : DiscoveryResult(index, target, "manual", 2)
    class Jellyfin(index: Int, target: CastTarget) : DiscoveryResult(index, target, "jellyfin", 3)
}

/**
 * Registry-driven discovery (SSDP + mDNS) with manual-IP fallback.
 * Devices persisted as "kind|usn|location|name" rows in SettingsStore.
 */
class DevicesRepository(
    private val client: HttpClient,
    private val settings: SettingsStore,
    private val jellyfin: JellyfinClient? = null,
) {
    private val tag = "DevicesRepository"

    // This view shares the caller-owned engine and is reused across scans. Close it
    // only after the parent client completes, so the caller remains the engine owner.
    private val enrichmentClient: HttpClient by lazy {
        client.config { followRedirects = false }.also { configured ->
            client.coroutineContext[Job]?.invokeOnCompletion { configured.close() }
        }
    }

    suspend fun scan(timeoutMs: Long = 5000): List<DiscoveredDevice> = coroutineScope {
        val deadlineMs = timeoutMs.coerceAtLeast(0)
        if (deadlineMs == 0L) return@coroutineScope emptyList()

        suspend fun <T> bestEffort(block: suspend () -> T): T? = try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            null
        }

        val results = supervisorScope {
            val completed = Channel<DiscoveryResult>(Channel.UNLIMITED)
            val enrichmentSlots = Semaphore(ENRICHMENT_CONCURRENCY)
            val nativeSearchWindowMs = (deadlineMs / 2).coerceAtLeast(1).coerceAtMost(Int.MAX_VALUE.toLong())
            val ssdpTargets = ReceiverRegistry.adapters.flatMap { it.ssdpTargets }.distinct()

            // Each worker publishes immutable result values through a channel. The
            // collector drains it only after all workers have stopped, so no child
            // mutates a result list owned by another dispatcher.
            val ssdpSearch = async {
                bestEffort { Bridges.ssdpSearch(ssdpTargets, nativeSearchWindowMs.toInt()) }
                    .orEmpty()
                    .mapNotNull(::validatedSsdp)
                    .also { valid -> Logger.i(tag) { "SSDP found ${valid.size} devices" } }
            }
            val ssdpEnrichment = async {
                val validSsdp = ssdpSearch.await()
                val jobs = validSsdp.mapIndexed { index, device ->
                    async {
                        bestEffort {
                            enrichmentSlots.withPermit {
                                ReceiverRegistry.adapters.firstNotNullOfOrNull {
                                    it.fromSsdp(device, enrichmentClient)
                                }
                            }
                        }?.let { target ->
                            completed.trySend(DiscoveryResult.Ssdp(index, target))
                        }
                    }
                }
                jobs.joinAll()
            }
            val mdnsSearch = async {
                if (ChromecastBridgeFactory.current == null) {
                    return@async
                }
                bestEffort {
                    discoverChromecast(nativeSearchWindowMs.toInt())
                }.orEmpty().forEachIndexed { index, device ->
                    completed.trySend(DiscoveryResult.Mdns(index, CastTarget.Chrome(device)))
                }
            }
            val jellyfinSearch = async {
                val service = jellyfin ?: return@async
                val base = settings.jellyfinServer().trim().trimEnd('/')
                val token = settings.jellyfinToken()
                val userId = settings.jellyfinUserId()
                if (base.isEmpty() || token.isEmpty() || userId.isEmpty()) return@async
                bestEffort { service.sessions(base, token, userId) }.orEmpty().forEachIndexed { index, session ->
                    completed.trySend(DiscoveryResult.Jellyfin(index, CastTarget.JellyfinSessionTarget(session)))
                }
            }
            val manualSearch = async {
                // Persisted manual rows start independently of SSDP; explicit manual
                // hostnames remain valid and retain their spelling.
                val manualRows = settings.manualDevices().mapNotNull { row ->
                    validatedManualParts(row.split('|'))
                }
                val jobs = manualRows.mapIndexed { index, parts ->
                    async {
                        bestEffort {
                            enrichmentSlots.withPermit {
                                ReceiverRegistry.adapters.firstOrNull { it.kind == parts[0] }
                                    ?.fromRow(parts, enrichmentClient)
                            }
                        }?.let { target ->
                            completed.trySend(DiscoveryResult.Manual(index, target))
                        }
                    }
                }
                jobs.joinAll()
            }

            val workers = listOf(ssdpSearch, ssdpEnrichment, mdnsSearch, jellyfinSearch, manualSearch)
            val finished = withTimeoutOrNull(deadlineMs) {
                workers.joinAll()
                true
            } == true
            if (!finished) {
                workers.forEach { it.cancel() }
                workers.joinAll()
            }

            completed.close()
            val drained = mutableListOf<DiscoveryResult>()
            for (result in completed) drained += result
            drained
        }

        val found = mutableListOf<DiscoveredDevice>()
        val identities = mutableSetOf<String>()
        fun append(target: CastTarget, via: String) {
            if (identities.add(canonicalTargetKey(target))) {
                found += DiscoveredDevice(target, via)
            }
        }
        results.sortedWith(compareBy<DiscoveryResult> { it.sourceOrder }.thenBy { it.index })
            .forEach { result -> append(result.target, result.via) }
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

    private companion object {
        const val ENRICHMENT_CONCURRENCY = 4
    }
}

private fun validatedSsdp(device: SsdpDevice): SsdpDevice? =
    safeNetworkLocation(device.location, device.responderAddress)?.let { location ->
        device.copy(location = location)
    }

private fun validatedManualParts(parts: List<String>): List<String>? {
    if (parts.size < 4) return null
    if (parts[0] == "chrome") return parts
    val location = safeNetworkLocation(parts[2], responderAddress = null, allowHostname = true) ?: return null
    return parts.toMutableList().also { it[2] = location }
}

private fun canonicalTargetKey(target: CastTarget): String = when (target) {
    is CastTarget.Dlna -> "dlna|" + (canonicalAuthority(target.device.location) ?: target.identityKey) + "|" + target.device.usn.trim().lowercase()
    is CastTarget.Roku -> "roku|${canonicalAuthority(target.device.location) ?: target.identityKey}"
    is CastTarget.Kodi -> "kodi|${canonicalAuthority(target.device.endpoint) ?: target.identityKey}"
    is CastTarget.Chrome -> {
        val host = canonicalIpAddress(target.device.host)?.text
            ?: target.device.host.trim().lowercase().trimEnd('.')
        "chrome|$host:${target.device.port}"
    }
    is CastTarget.JellyfinSessionTarget -> target.identityKey
}

private fun canonicalAuthority(raw: String): String? {
    val url = runCatching { Url(raw) }.getOrNull() ?: return null
    val host = url.host.trim().trim('[', ']').trimEnd('.')
    if (host.isEmpty()) return null
    val canonical = canonicalIpAddress(host)?.text ?: host.lowercase()
    return "${url.protocol.name.lowercase()}://$canonical:${url.port}"
}

/**
 * Discovery LOCATION policy. SSDP hostnames are accepted only when native SSDP pins
 * the response to its recvfrom address; explicit manual rows may retain a hostname.
 * Numeric loopback/unspecified addresses and malformed authorities are always rejected.
 */
private fun safeNetworkLocation(
    raw: String,
    responderAddress: String?,
    allowHostname: Boolean = false,
): String? {
    val location = raw.trim()
    val url = runCatching { Url(location) }.getOrNull() ?: return null
    val scheme = url.protocol.name.lowercase()
    if (scheme != "http" && scheme != "https") return null

    val authorityStart = location.indexOf("://").takeIf { it >= 0 }?.plus(3) ?: return null
    val authorityEnd = location.indexOfFirstFrom(authorityStart) { it == '/' || it == '?' || it == '#' }
        .let { if (it < 0) location.length else it }
    if (location.substring(authorityStart, authorityEnd).contains('@')) return null

    val locationHost = url.host.trim().trim('[', ']').trimEnd('.')
    if (locationHost.isEmpty() || locationHost.equals("localhost", ignoreCase = true) ||
        locationHost.endsWith(".localhost", ignoreCase = true)
    ) return null
    val locationAddress = canonicalIpAddress(locationHost)
    if (!allowHostname && locationAddress == null && looksNumericHost(locationHost)) return null

    val responder = responderAddress?.trim()?.takeIf { it.isNotEmpty() }
    val responderAddressValue = if (responder == null) {
        null
    } else {
        canonicalIpAddress(responder) ?: return null
    }
    val chosen = responderAddressValue ?: locationAddress
    if (chosen == null) return location.takeIf { allowHostname }
    if (chosen.isLoopbackOrUnspecified) return null
    return replaceAuthorityHost(location, authorityStart, authorityEnd, chosen.text)
}

private fun replaceAuthorityHost(raw: String, authorityStart: Int, authorityEnd: Int, host: String): String {
    val authority = raw.substring(authorityStart, authorityEnd)
    val hostEnd = if (authority.startsWith("[")) {
        authority.indexOf(']').takeIf { it >= 0 }?.plus(1) ?: authority.length
    } else {
        val colon = authority.lastIndexOf(':')
        if (colon >= 0 && authority.substring(colon + 1).toIntOrNull() != null) colon else authority.length
    }
    val port = authority.substring(hostEnd)
    val renderedHost = if (host.contains(':')) "[$host]" else host
    return raw.substring(0, authorityStart) + renderedHost + port + raw.substring(authorityEnd)
}

private fun looksNumericHost(host: String): Boolean =
    host.isNotEmpty() && host.all { it.isDigit() || it == '.' || it == ':' || it == 'x' ||
        it == 'X' || it in 'a'..'f' || it in 'A'..'F' }

private fun String.indexOfFirstFrom(startIndex: Int, predicate: (Char) -> Boolean): Int {
    for (index in startIndex until length) {
        if (predicate(this[index])) return index
    }
    return -1
}
