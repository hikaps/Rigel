package app.rigel.cast.dlna

import app.rigel.cast.DlnaDevice
import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.userAgent

/**
 * Device-description parsing (no SCRD fetch per plan): extracts friendlyName,
 * the AVTransport controlURL, and (when present) the RenderingControl
 * controlURL used for volume. Pure function — unit-testable.
 */
object DlnaDeviceDescription {
    fun parse(usn: String, location: String, deviceXml: String): DlnaDevice? {
        val friendlyName = Regex("""<friendlyName>\s*([^<]+?)\s*</friendlyName>""")
            .find(deviceXml)?.groupValues?.get(1)?.trim() ?: return null
        val servicesBlock = Regex(
            """<serviceList>.*?</serviceList>""",
            RegexOption.DOT_MATCHES_ALL,
        ).find(deviceXml)?.value ?: return null

        val serviceBlocks = Regex(
            """<service>.*?</service>""",
            RegexOption.DOT_MATCHES_ALL,
        ).findAll(servicesBlock).toList()

        var avControlUrl: String? = null
        var eventSubUrl: String? = null
        var renderingControlUrl: String? = null

        fun controlUrlOf(serviceXml: String): String? =
            Regex("""<controlURL>\s*([^<]+?)\s*</controlURL>""")
                .find(serviceXml)?.groupValues?.get(1)?.trim()

        for (service in serviceBlocks) {
            val serviceType = Regex("""<serviceType>\s*([^<]+?)\s*</serviceType>""")
                .find(service.value)?.groupValues?.getOrNull(1).orEmpty()
            when {
                serviceType.contains("AVTransport") && avControlUrl == null -> {
                    avControlUrl = controlUrlOf(service.value) ?: return null
                    eventSubUrl = Regex("""<eventSubURL>\s*([^<]+?)\s*</eventSubURL>""")
                        .find(service.value)?.groupValues?.get(1)?.trim()
                }
                serviceType.contains("RenderingControl") && renderingControlUrl == null -> {
                    renderingControlUrl = controlUrlOf(service.value)
                }
            }
        }

        val control = avControlUrl ?: return null
        return DlnaDevice(
            usn = usn,
            location = location,
            friendlyName = friendlyName,
            controlUrl = resolveUrl(location, control),
            renderingControlUrl = renderingControlUrl?.let { resolveUrl(location, it) },
            eventSubUrl = eventSubUrl,
        )
    }

    /** controlURL is often relative; resolve against the LOCATION origin. */
    internal fun resolveUrl(location: String, controlUrl: String): String {
        if (controlUrl.startsWith("http://") || controlUrl.startsWith("https://")) return controlUrl
        return if (controlUrl.startsWith("/")) {
            val scheme = if (location.startsWith("https")) "https" else "http"
            "$scheme://${location.removePrefix("http://").removePrefix("https://").substringBefore('/')}$controlUrl"
        } else {
            location.substringBeforeLast('/', location) + "/" + controlUrl
        }
    }
}

/** DLNA renderer control over UPnP AVTransport (playback) and RenderingControl (volume) SOAP. */
class DlnaRenderer(private val client: HttpClient) {
    private val tag = "DlnaRenderer"

    suspend fun fetchDeviceDescription(usn: String, location: String): DlnaDevice? {
        val xml = runCatching { client.get(location).bodyAsText() }.getOrNull() ?: return null
        return DlnaDeviceDescription.parse(usn, location, xml)
    }

    /** True when the renderer accepted the URI (SOAP round-trip succeeded). */
    suspend fun setAvTransportUri(device: DlnaDevice, uri: String, title: String?): Boolean {
        val body = DlnaSoap.setAvTransportUriBody(uri, title)
        return runCatching {
            val resp = client.post(device.controlUrl) {
                contentType(ContentType.Text.Xml)
                userAgent("Rigel/1.0")
                header("SOAPACTION", "\"${DlnaSoap.SERVICE_TYPE}#SetAVTransportURI\"")
                setBody(body)
            }
            Logger.i(tag) { "SetAVTransportURI -> ${resp.status}" }
            resp.status.value in 200..299
        }.onFailure {
            Logger.w(tag, it) { "SetAVTransportURI failed: ${device.friendlyName}" }
        }.getOrDefault(false)
    }

    suspend fun play(device: DlnaDevice): Boolean = control(device, "Play", DlnaSoap.playBody())
    suspend fun pause(device: DlnaDevice): Boolean = control(device, "Pause", DlnaSoap.pauseBody())
    suspend fun resume(device: DlnaDevice): Boolean = play(device)
    suspend fun stop(device: DlnaDevice): Boolean = control(device, "Stop", DlnaSoap.stopBody())
    suspend fun seek(device: DlnaDevice, positionMs: Long): Boolean =
        control(device, "Seek", DlnaSoap.seekBody(positionMs))
    suspend fun position(device: DlnaDevice): Pair<Long, Long>? {
        val xml = postForBody(device, "GetPositionInfo", DlnaSoap.getPositionInfoBody()) ?: return null
        return DlnaSoap.parsePositionInfo(xml)
    }

    suspend fun transportState(device: DlnaDevice): String? {
        val xml = postForBody(device, "GetTransportInfo", DlnaSoap.getTransportStateBody()) ?: return null
        return DlnaSoap.parseTransportState(xml)
    }

    suspend fun volumeUp(device: DlnaDevice): Boolean = adjustVolume(device, VOLUME_STEP)

    suspend fun volumeDown(device: DlnaDevice): Boolean = adjustVolume(device, -VOLUME_STEP)

    /** Read the master volume, then step it by [delta] within 0..100. */
    private suspend fun adjustVolume(device: DlnaDevice, delta: Int): Boolean {
        val url = device.renderingControlUrl ?: return false
        val xml = postForBody(
            url,
            DlnaSoap.RENDERING_CONTROL_TYPE,
            "GetVolume",
            DlnaSoap.getVolumeBody(),
            device.friendlyName,
        ) ?: return false
        val current = DlnaSoap.parseVolume(xml) ?: return false
        val target = (current + delta).coerceIn(0, 100)
        return postForBody(
            url,
            DlnaSoap.RENDERING_CONTROL_TYPE,
            "SetVolume",
            DlnaSoap.setVolumeBody(target),
            device.friendlyName,
        ) != null
    }

    suspend fun toggleMute(device: DlnaDevice): Boolean {
        val url = device.renderingControlUrl ?: return false
        val xml = postForBody(
            url,
            DlnaSoap.RENDERING_CONTROL_TYPE,
            "GetMute",
            DlnaSoap.getMuteBody(),
            device.friendlyName,
        ) ?: return false
        val muted = DlnaSoap.parseMuted(xml) ?: return false
        return postForBody(
            url,
            DlnaSoap.RENDERING_CONTROL_TYPE,
            "SetMute",
            DlnaSoap.setMuteBody(!muted),
            device.friendlyName,
        ) != null
    }

    /** True when the SOAP action round-tripped successfully. */
    private suspend fun control(device: DlnaDevice, action: String, body: String): Boolean =
        postForBody(device, action, body) != null

    private suspend fun postForBody(device: DlnaDevice, action: String, body: String): String? =
        postForBody(device.controlUrl, DlnaSoap.SERVICE_TYPE, action, body, device.friendlyName)

    private suspend fun postForBody(
        serviceUrl: String,
        serviceType: String,
        action: String,
        body: String,
        deviceName: String,
    ): String? {
        return runCatching {
            val response = client.post(serviceUrl) {
                contentType(ContentType.Text.Xml)
                userAgent("Rigel/1.0")
                header("SOAPACTION", "\"$serviceType#$action\"")
                setBody(body)
            }
            if (response.status.value !in 200..299) return@runCatching null
            response.bodyAsText()
        }.onFailure { Logger.w(tag, it) { "$action failed: $deviceName" } }.getOrNull()
    }

    private companion object {
        const val VOLUME_STEP = 10
    }
}
