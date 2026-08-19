package app.rigel.cast.dlna

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class DlnaSoapTest {

    @Test
    fun setAvTransportUriBodyMatchesExpectedXml() {
        val body = DlnaSoap.setAvTransportUriBody(
            "http://192.168.1.5:8080/movie.mp4",
            "My & Movie",
        )
        val expected =
            """<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>http://192.168.1.5:8080/movie.mp4</CurrentURI><CurrentURIMetaData>&lt;DIDL-Lite xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot; xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot;&gt;&lt;item&gt;&lt;dc:title&gt;My &amp; Movie&lt;/dc:title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>"""
        assertEquals(expected, body)
    }

    @Test
    fun metadataEmptyWhenNoTitle() {
        assertEquals("", DlnaSoap.metadata(null))
        assertEquals("", DlnaSoap.metadata("  "))
    }

    @Test
    fun playBodyHasSpeedOne() {
        val body = DlnaSoap.playBody()
        assertEquals(true, body.contains("""<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">"""))
        assertEquals(true, body.contains("<Speed>1</Speed>"))
    }

    @Test
    fun getPositionInfoResponseParsesToMs() {
        val xml = """<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
            <s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
            <TrackDuration>01:23:45</TrackDuration><RelTime>00:01:02.500</RelTime>
            </u:GetPositionInfoResponse></s:Body></s:Envelope>"""
        val parsed = DlnaSoap.parsePositionInfo(xml)
        assertNotNull(parsed)
        assertEquals(62_500, parsed.first)
        assertEquals(5_025_000, parsed.second)
    }

    @Test
    fun shortRelTimeFormatsParse() {
        assertEquals(3_000, DlnaSoap.parseRelTime("0:00:03"))
        assertEquals(3_000, DlnaSoap.parseRelTime("00:03"))
        assertNull(DlnaSoap.parseRelTime("bogus"))
    }

    @Test
    fun seekBodyFormatsTime() {
        assertEquals("00:01:30", DlnaSoap.formatTime(90_000))
        assertEquals("01:00:00", DlnaSoap.formatTime(3_600_000))
    }

    @Test
    fun xmlEscapeEscapesSpecialChars() {
        assertEquals("a&amp;b&lt;c&gt;d&quot;e&apos;f", DlnaSoap.xmlEscape("""a&b<c>d"e'f"""))
    }

    @Test
    fun transportStateParses() {
        assertEquals("PLAYING", DlnaSoap.parseTransportState("<CurrentTransportState>PLAYING</CurrentTransportState>"))
        assertEquals(
            "NO_MEDIA_PRESENT",
            DlnaSoap.parseTransportState("<CurrentTransportState>\n NO_MEDIA_PRESENT \n</CurrentTransportState>"),
        )
    }
}
