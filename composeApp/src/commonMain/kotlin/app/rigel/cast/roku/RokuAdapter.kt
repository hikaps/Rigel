package app.rigel.cast.roku

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastResult
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverAdapter
import io.ktor.client.HttpClient

object RokuAdapter : ReceiverAdapter {
    override val kind = "roku"

    override val ssdpTargets = listOf("roku:ecp")

    override fun matches(target: CastTarget): Boolean = target is CastTarget.Roku

    override fun capabilities() = CastCapabilities(
        supportsSeek = false,
        supportsPosition = false,
        note = "Roku ECP media playback has no seek or position tracking",
    )

    override suspend fun cast(
        target: CastTarget,
        url: String,
        title: String,
        client: HttpClient,
    ): CastResult {
        val device = (target as CastTarget.Roku).device
        val ok = RokuRenderer(client).launchPlayOnRoku(device, url)
        return if (ok) {
            CastResult.Sent("Sent to ${target.name}")
        } else {
            CastResult.Rejected("Roku launch failed (Play on Roku channel required)")
        }
    }

    override suspend fun fromSsdp(device: SsdpDevice, client: HttpClient): CastTarget? {
        if (!device.searchTarget.contains("roku:ecp")) return null
        return RokuRenderer(client).fetchDeviceInfo(device.usn, device.location)
            ?.let { CastTarget.Roku(it) }
    }

    override suspend fun fromRow(parts: List<String>, client: HttpClient): CastTarget? {
        return RokuRenderer(client).fetchDeviceInfo(parts[1], parts[2])
            ?.let { CastTarget.Roku(it) }
    }

    override suspend fun probeManual(ip: String, client: HttpClient): CastTarget? {
        val location = "http://$ip:8060/"
        val device = runCatching {
            RokuRenderer(client).fetchDeviceInfo("manual-roku-$ip", location)
        }.getOrNull() ?: return null
        return CastTarget.Roku(device)
    }

    override fun rowFor(target: CastTarget): String {
        val d = (target as CastTarget.Roku).device
        return "roku|${d.usn}|${d.location}|${d.modelName ?: "Roku"}"
    }
}
