package app.rigel.cast.kodi

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverAdapter
import io.ktor.client.HttpClient

object KodiAdapter : ReceiverAdapter {
    override val kind = "kodi"

    override fun matches(target: CastTarget): Boolean = target is CastTarget.Kodi

    override fun capabilities() = CastCapabilities(
        supportsSeek = true,
        supportsPosition = true,
        note = null,
    )

    override suspend fun cast(
        target: CastTarget,
        url: String,
        title: String,
        client: HttpClient,
    ): String {
        val device = (target as CastTarget.Kodi).device
        val ok = KodiRenderer(client).launch(device.endpoint, url)
        return if (ok) "Sent to ${target.name}" else "Kodi rejected the URL"
    }

    override suspend fun fromSsdp(device: SsdpDevice, client: HttpClient): CastTarget? {
        if (!device.searchTarget.contains("MediaRenderer")) return null
        val host = device.location
            .removePrefix("http://").removePrefix("https://")
            .substringBefore('/').substringBefore(':')
        val endpoint = "http://$host:8080"
        return if (KodiRenderer(client).isKodi(endpoint)) {
            CastTarget.Kodi(KodiDevice("kodi-${device.usn}", endpoint, "Kodi"))
        } else null
    }

    override suspend fun seek(
        target: CastTarget,
        positionMs: Long,
        durationMs: Long,
        client: HttpClient,
    ): Boolean {
        if (durationMs <= 0) return false
        val device = (target as CastTarget.Kodi).device
        val percent = (positionMs.toDouble() * 100.0 / durationMs).coerceIn(0.0, 100.0)
        return runCatching { KodiRenderer(client).seek(device.endpoint, percent) }
            .getOrNull()
            ?.let { !it.contains("\"error\"") }
            ?: false
    }


    override suspend fun fromRow(parts: List<String>, client: HttpClient): CastTarget? =
        CastTarget.Kodi(KodiDevice(parts[1], parts[2], parts[3]))

    override suspend fun probeManual(ip: String, client: HttpClient): CastTarget? {
        val endpoint = "http://$ip:8080"
        return if (KodiRenderer(client).isKodi(endpoint)) {
            CastTarget.Kodi(KodiDevice("manual-kodi-$ip", endpoint, "Kodi"))
        } else null
    }

    override fun rowFor(target: CastTarget): String {
        val d = (target as CastTarget.Kodi).device
        return "kodi|${d.usn}|${d.endpoint}|${d.name}"
    }
}
