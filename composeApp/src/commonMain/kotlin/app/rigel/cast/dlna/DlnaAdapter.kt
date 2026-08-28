package app.rigel.cast.dlna

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverAdapter
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
object DlnaAdapter : ReceiverAdapter {
    override val kind = "dlna"

    override val ssdpTargets = listOf("urn:schemas-upnp-org:device:MediaRenderer:1")

    override fun matches(target: CastTarget): Boolean = target is CastTarget.Dlna

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
        val device = (target as CastTarget.Dlna).device
        val renderer = DlnaRenderer(client)
        val uriAccepted = renderer.setAvTransportUri(device, url, title)
        val playbackStarted = uriAccepted && renderer.play(device)
        return if (playbackStarted) {
            "Sent to ${target.name}"
        } else {
            "DLNA rejected the URL"
        }
    }

    override suspend fun seek(
        target: CastTarget,
        positionMs: Long,
        durationMs: Long,
        client: HttpClient,
    ): Boolean = runCatching {
        DlnaRenderer(client).seek((target as CastTarget.Dlna).device, positionMs)
    }.getOrDefault(false)


    /**
     * Bug fix: live MediaRenderer SSDP responses now enrich into DLNA targets.
     * Previously only the literal "dlna" search target (manual rows) was handled.
     */
    override suspend fun fromSsdp(device: SsdpDevice, client: HttpClient): CastTarget? {
        if (!device.searchTarget.contains("MediaRenderer")) return null
        val xml = runCatching { client.get(device.location).bodyAsText() }.getOrNull()
            ?: return null
        val d = DlnaDeviceDescription.parse(device.usn, device.location, xml) ?: return null
        return CastTarget.Dlna(d)
    }

    override suspend fun fromRow(parts: List<String>, client: HttpClient): CastTarget? {
        val xml = runCatching { client.get(parts[2]).bodyAsText() }.getOrNull()
            ?: return null
        val d = DlnaDeviceDescription.parse(parts[1], parts[2], xml) ?: return null
        return CastTarget.Dlna(d)
    }

    override suspend fun probeManual(ip: String, client: HttpClient): CastTarget? {
        val location = "http://$ip/rootDesc.xml"
        val xml = runCatching { client.get(location).bodyAsText() }.getOrNull()
            ?: return null
        val usn = "manual-dlna-$ip"
        val device = DlnaDeviceDescription.parse(usn, location, xml) ?: return null
        return CastTarget.Dlna(device)
    }

    override fun rowFor(target: CastTarget): String {
        val d = (target as CastTarget.Dlna).device
        return "dlna|${d.usn}|${d.location}|${d.friendlyName}"
    }
}
