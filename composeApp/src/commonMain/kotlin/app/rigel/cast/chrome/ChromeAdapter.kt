package app.rigel.cast.chrome

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastResult
import app.rigel.cast.CastTarget
import app.rigel.cast.ChromeDevice
import app.rigel.cast.ReceiverAdapter
import io.ktor.client.HttpClient

object ChromeAdapter : ReceiverAdapter {
    override val kind = "chrome"

    override fun matches(target: CastTarget): Boolean = target is CastTarget.Chrome

    override fun capabilities() = CastCapabilities(
        supportsSeek = false,
        supportsPosition = false,
        note = "Chromecast playback continues on the device; control it there",
    )

    override suspend fun cast(
        target: CastTarget,
        url: String,
        title: String,
        client: HttpClient,
    ): CastResult {
        val bridge = ChromecastBridgeFactory.current
            ?: return CastResult.Rejected("Chromecast bridge not registered")
        return ChromeRenderer(bridge).launch((target as CastTarget.Chrome).device, url, title)
    }

    override suspend fun fromSsdp(device: SsdpDevice, client: HttpClient): CastTarget? = null

    override suspend fun fromRow(parts: List<String>, client: HttpClient): CastTarget? {
        val endpoint = parseEndpoint(parts.getOrNull(2) ?: return null) ?: return null
        return CastTarget.Chrome(
            ChromeDevice(
                id = parts.getOrNull(1) ?: return null,
                host = endpoint.first,
                port = endpoint.second,
                name = parts.getOrNull(3).orEmpty(),
            ),
        )
    }

    override suspend fun probeManual(ip: String, client: HttpClient): CastTarget? {
        val bridge = ChromecastBridgeFactory.current ?: return null
        val port = 8009
        if (!ChromeRenderer(bridge).probe(ip, port)) return null
        return CastTarget.Chrome(ChromeDevice("manual-chrome-$ip", ip, port, "Chromecast"))
    }

    override fun rowFor(target: CastTarget): String {
        val device = (target as CastTarget.Chrome).device
        return "chrome|${device.id}|${device.host}:${device.port}|${device.name}"
    }

    private fun parseEndpoint(value: String): Pair<String, Int>? {
        val host = value.substringBeforeLast(':', missingDelimiterValue = value)
        val port = value.substringAfterLast(':', "8009").toIntOrNull() ?: return null
        if (host.isBlank()) return null
        return host to port
    }
}
