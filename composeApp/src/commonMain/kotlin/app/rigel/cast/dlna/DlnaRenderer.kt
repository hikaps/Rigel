package app.rigel.cast.dlna

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

data class DlnaDevice(
    val usn: String,
    val location: String,
    val friendlyName: String,
    val controlUrl: String,
    val eventSubUrl: String? = null,
)

/**
 * Device-description parsing (no SCRD fetch per plan): extracts friendlyName
 * and the AVTransport controlURL. Pure function — unit-testable.
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

        for (service in serviceBlocks) {
            val serviceType = Regex("""<serviceType>\s*([^<]+?)\s*</serviceType>""")
                .find(service.value)?.groupValues?.get(1)?.orEmpty()
            if (serviceType?.contains("AVTransport") == true) {
                val control = Regex("""<controlURL>\s*([^<]+?)\s*</controlURL>""")
                    .find(service.value)?.groupValues?.get(1)?.trim() ?: return null
                return DlnaDevice(
                    usn = usn,
                    location = location,
                    friendlyName = friendlyName,
                    controlUrl = resolveUrl(location, control),
                    eventSubUrl = Regex("""<eventSubURL>\s*([^<]+?)\s*</eventSubURL>""")
                        .find(service.value)?.groupValues?.get(1)?.trim(),
                )
            }
        }
        return null
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

/** DLNA renderer control over UPnP AVTransport SOAP. */
class DlnaRenderer(private val client: HttpClient) {
    private val tag = "DlnaRenderer"

    suspend fun fetchDeviceDescription(usn: String, location: String): DlnaDevice? {
        val xml = runCatching { client.get(location).bodyAsText() }.getOrNull() ?: return null
        return DlnaDeviceDescription.parse(usn, location, xml)
    }

    suspend fun setAvTransportUri(device: DlnaDevice, uri: String, title: String?) {
        val body = DlnaSoap.setAvTransportUriBody(uri, title)
        val resp = client.post(device.controlUrl) {
            contentType(ContentType.Text.Xml)
            userAgent("Rigel/1.0")
            header("SOAPACTION", "\"${DlnaSoap.SERVICE_TYPE}#SetAVTransportURI\"")
            setBody(body)
        }
        Logger.i(tag) { "SetAVTransportURI -> ${resp.status}" }
    }

    suspend fun play(device: DlnaDevice) = control(device, "Play", DlnaSoap.playBody())
    suspend fun pause(device: DlnaDevice) = control(device, "Pause", DlnaSoap.pauseBody())
    suspend fun stop(device: DlnaDevice) = control(device, "Stop", DlnaSoap.stopBody())
    suspend fun seek(device: DlnaDevice, positionMs: Long) =
        control(device, "Seek", DlnaSoap.seekBody(positionMs))

    suspend fun position(device: DlnaDevice): Pair<Long, Long>? {
        val xml = postForBody(device, "GetPositionInfo", DlnaSoap.getPositionInfoBody()) ?: return null
        return DlnaSoap.parsePositionInfo(xml)
    }

    suspend fun transportState(device: DlnaDevice): String? {
        val xml = postForBody(device, "GetTransportInfo", DlnaSoap.getTransportStateBody()) ?: return null
        return DlnaSoap.parseTransportState(xml)
    }

    private suspend fun control(device: DlnaDevice, action: String, body: String) {
        postForBody(device, action, body)
    }

    private suspend fun postForBody(device: DlnaDevice, action: String, body: String): String? {
        return runCatching {
            client.post(device.controlUrl) {
                contentType(ContentType.Text.Xml)
                userAgent("Rigel/1.0")
                header("SOAPACTION", "\"${DlnaSoap.SERVICE_TYPE}#$action\"")
                setBody(body)
            }.bodyAsText()
        }.onFailure { Logger.w(tag, it) { "$action failed: ${device.friendlyName}" } }.getOrNull()
    }
}
