package app.rigel.cast.dlna

/**
 * Pure SOAP/XML builders and parsers for UPnP AVTransport (DLNA).
 * Shapes follow the UPnP AV spec and the working go2tv sender.
 * Unit-tested with exact expected XML.
 */
object DlnaSoap {
    const val SERVICE_TYPE = "urn:schemas-upnp-org:service:AVTransport:1"

    fun envelope(action: String, argsXml: String): String =
        """<?xml version="1.0" encoding="utf-8"?>""" +
            """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" """ +
            """s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">""" +
            """<s:Body><u:$action xmlns:u="$SERVICE_TYPE">$argsXml</u:$action></s:Body></s:Envelope>"""

    fun setAvTransportUriBody(uri: String, title: String?): String =
        envelope(
            "SetAVTransportURI",
            "<InstanceID>0</InstanceID>" +
                "<CurrentURI>${xmlEscape(uri)}</CurrentURI>" +
                "<CurrentURIMetaData>${xmlEscape(metadata(title))}</CurrentURIMetaData>",
        )

    fun metadata(title: String?): String =
        if (title.isNullOrBlank()) {
            ""
        } else {
            // Raw title; caller (setAvTransportUriBody) escapes the whole fragment once.
            """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/""" +
                """" xmlns:dc="http://purl.org/dc/elements/1.1/"><item><dc:title>""" +
                title + """</dc:title></item></DIDL-Lite>"""
        }

    fun playBody(): String = envelope("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>")
    fun pauseBody(): String = envelope("Pause", "<InstanceID>0</InstanceID>")
    fun stopBody(): String = envelope("Stop", "<InstanceID>0</InstanceID>")

    fun seekBody(positionMs: Long): String =
        envelope(
            "Seek",
            "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${formatTime(positionMs)}</Target>",
        )

    fun getPositionInfoBody(): String = envelope("GetPositionInfo", "<InstanceID>0</InstanceID>")

    fun getTransportStateBody(): String =
        envelope("GetTransportInfo", "<InstanceID>0</InstanceID>")

    fun parsePositionInfo(responseXml: String): Pair<Long, Long>? {
        val rel = parseTime(responseXml, "RelTime") ?: return null
        val duration = parseTime(responseXml, "TrackDuration") ?: return null
        return rel to duration
    }

    fun parseTransportState(responseXml: String): String? =
        Regex("""<CurrentTransportState>\s*([^<]+?)\s*</CurrentTransportState>""")
            .find(responseXml)?.groupValues?.get(1)?.trim()

    private fun parseTime(xml: String, tag: String): Long? {
        val match = Regex("""<$tag>\s*([^<]+?)\s*</$tag>""").find(xml) ?: return null
        return parseRelTime(match.groupValues[1])
    }

    /** "HH:MM:SS[.mmm]" or "H:MM:SS" → milliseconds. */
    internal fun parseRelTime(value: String): Long? {
        val t = value.trim()
        val parts = t.split(':')
        if (parts.size < 2 || parts.size > 3) return null
        val secPart = parts.last()
        val secFrac = secPart.split('.')
        val secs = secFrac[0].toLongOrNull() ?: return null
        val millis = if (secFrac.size > 1) {
            secFrac[1].take(3).padEnd(3, '0').toLongOrNull() ?: 0L
        } else 0L
        val minutes = if (parts.size >= 2) parts[parts.size - 2].toLongOrNull() ?: return null else 0L
        val hours = if (parts.size == 3) parts[0].toLongOrNull() ?: return null else 0L
        return ((hours * 3600 + minutes * 60 + secs) * 1000) + millis
    }

    internal fun formatTime(ms: Long): String {
        val totalSecs = (ms.coerceAtLeast(0)) / 1000
        val h = totalSecs / 3600
        val m = (totalSecs % 3600) / 60
        val s = totalSecs % 60
        return h.toString().padStart(2, '0') + ":" +
            m.toString().padStart(2, '0') + ":" +
            s.toString().padStart(2, '0')
    }

    internal fun xmlEscape(s: String): String =
        s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")
}
