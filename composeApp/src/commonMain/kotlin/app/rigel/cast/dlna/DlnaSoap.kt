package app.rigel.cast.dlna

import app.rigel.cast.CastMediaKind
import app.rigel.cast.PreparedCastMedia
/** Pure SOAP/XML builders and parsers for UPnP AVTransport and DLNA capabilities. */
object DlnaSoap {
    const val SERVICE_TYPE = "urn:schemas-upnp-org:service:AVTransport:1"
    const val RENDERING_CONTROL_TYPE = "urn:schemas-upnp-org:service:RenderingControl:1"
    const val CONNECTION_MANAGER_TYPE = "urn:schemas-upnp-org:service:ConnectionManager:1"

    fun envelope(action: String, argsXml: String, serviceType: String = SERVICE_TYPE): String =
        """<?xml version="1.0" encoding="utf-8"?>""" +
            """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" """ +
            """s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:$action xmlns:u="$serviceType">$argsXml</u:$action></s:Body></s:Envelope>"""

    fun setAvTransportUriBody(uri: String, title: String?): String =
        envelope(
            "SetAVTransportURI",
            "<InstanceID>0</InstanceID>" +
                "<CurrentURI>${xmlEscape(uri)}</CurrentURI>" +
                "<CurrentURIMetaData>${xmlEscape(metadata(title))}</CurrentURIMetaData>",
        )

    fun metadata(title: String?): String =
        if (title.isNullOrBlank()) "" else
            """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/"><item><dc:title>$title</dc:title></item></DIDL-Lite>"""

    fun metadata(media: PreparedCastMedia): String {
        val itemClass = if (media.kind == CastMediaKind.AUDIO) "object.item.audioItem" else "object.item.videoItem"
        return """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="0" restricted="1"><dc:title>${xmlEscape(media.title)}</dc:title><upnp:class>$itemClass</upnp:class><res protocolInfo="http-get:*:${xmlEscape(media.contentType)}:*">${xmlEscape(media.url)}</res></item></DIDL-Lite>"""
    }

    fun setAvTransportUriBody(media: PreparedCastMedia): String =
        envelope("SetAVTransportURI", "<InstanceID>0</InstanceID><CurrentURI>${xmlEscape(media.url)}</CurrentURI><CurrentURIMetaData>${xmlEscape(metadata(media))}</CurrentURIMetaData>")
    fun playBody(): String = envelope("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
    fun pauseBody(): String = envelope("Pause", "<InstanceID>0</InstanceID>")
    fun stopBody(): String = envelope("Stop", "<InstanceID>0</InstanceID>")
    fun getPositionInfoBody(): String = envelope("GetPositionInfo", "<InstanceID>0</InstanceID>")
    fun getTransportStateBody(): String = envelope("GetTransportInfo", "<InstanceID>0</InstanceID>")
    fun getProtocolInfoBody(): String = envelope("GetProtocolInfo", "", CONNECTION_MANAGER_TYPE)

    fun seekBody(positionMs: Long): String =
        envelope("Seek", "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${formatTime(positionMs)}</Target>")

    fun setVolumeBody(volume: Int): String =
        envelope(
            "SetVolume",
            "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$volume</DesiredVolume>",
            RENDERING_CONTROL_TYPE,
        )

    fun getVolumeBody(): String =
        envelope("GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>", RENDERING_CONTROL_TYPE)

    fun setMuteBody(muted: Boolean): String =
        envelope(
            "SetMute",
            "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>${if (muted) 1 else 0}</DesiredMute>",
            RENDERING_CONTROL_TYPE,
        )

    fun getMuteBody(): String =
        envelope("GetMute", "<InstanceID>0</InstanceID><Channel>Master</Channel>", RENDERING_CONTROL_TYPE)

    fun parseSinkProtocolInfo(responseXml: String): String? =
        Regex("""<Sink>\s*([^<]*)\s*</Sink>""").find(responseXml)?.groupValues?.get(1)?.trim()?.takeIf { it.isNotEmpty() }

    fun parseVolume(responseXml: String): Int? =
        Regex("""<CurrentVolume>\s*(\d+)\s*</CurrentVolume>""").find(responseXml)?.groupValues?.get(1)?.toIntOrNull()

    fun parseMuted(responseXml: String): Boolean? =
        Regex("""<CurrentMute>\s*([01])\s*</CurrentMute>""").find(responseXml)?.groupValues?.get(1)?.let { it == "1" }

    fun parsePositionInfo(responseXml: String): Pair<Long, Long>? {
        val rel = parseTime(responseXml, "RelTime") ?: return null
        val duration = parseTime(responseXml, "TrackDuration") ?: return null
        return rel to duration
    }

    fun parseTransportState(responseXml: String): String? =
        Regex("""<CurrentTransportState>\s*([^<]+?)\s*</CurrentTransportState>""").find(responseXml)?.groupValues?.get(1)?.trim()

    private fun parseTime(xml: String, tag: String): Long? {
        val match = Regex("""<$tag>\s*([^<]+?)\s*</$tag>""").find(xml) ?: return null
        return parseRelTime(match.groupValues[1])
    }

    internal fun parseRelTime(value: String): Long? {
        val parts = value.trim().split(':')
        if (parts.size !in 2..3) return null
        val secFrac = parts.last().split('.')
        val secs = secFrac[0].toLongOrNull() ?: return null
        val millis = if (secFrac.size > 1) secFrac[1].take(3).padEnd(3, '0').toLongOrNull() ?: 0L else 0L
        val minutes = parts[parts.size - 2].toLongOrNull() ?: return null
        val hours = if (parts.size == 3) parts[0].toLongOrNull() ?: return null else 0L
        return ((hours * 3600 + minutes * 60 + secs) * 1000) + millis
    }

    internal fun formatTime(ms: Long): String {
        val totalSecs = ms.coerceAtLeast(0) / 1000
        val h = totalSecs / 3600
        val m = (totalSecs % 3600) / 60
        val s = totalSecs % 60
        return h.toString().padStart(2, '0') + ":" + m.toString().padStart(2, '0') + ":" + s.toString().padStart(2, '0')
    }

    internal fun xmlEscape(s: String): String =
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace("\"", "&quot;").replace("'", "&apos;")
}
