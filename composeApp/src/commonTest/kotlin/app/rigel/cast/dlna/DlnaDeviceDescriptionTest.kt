package app.rigel.cast.dlna

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class DlnaDeviceDescriptionTest {

    private val deviceXml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <friendlyName>Living Room TV</friendlyName>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/upnp/control/AVTransport1</controlURL>
                <eventSubURL>/upnp/event/AVTransport1</eventSubURL>
              </service>
            </serviceList>
          </device>
        </root>
    """.trimIndent()

    @Test
    fun parsesFriendlyNameControlAndEventUrls() {
        val device = DlnaDeviceDescription.parse("usn-1", "http://10.0.0.5:1234/desc.xml", deviceXml)
        assertNotNull(device)
        assertEquals("usn-1", device.usn)
        assertEquals("Living Room TV", device.friendlyName)
        assertEquals("http://10.0.0.5:1234/upnp/control/AVTransport1", device.controlUrl)
        assertEquals("/upnp/event/AVTransport1", device.eventSubUrl)
    }

    @Test
    fun missingFriendlyNameReturnsNull() {
        val xml = """<root><device><serviceList></serviceList></device></root>"""
        assertNull(DlnaDeviceDescription.parse("u", "http://h/desc.xml", xml))
    }

    @Test
    fun missingServiceListReturnsNull() {
        val xml = """<root><device><friendlyName>TV</friendlyName></device></root>"""
        assertNull(DlnaDeviceDescription.parse("u", "http://h/desc.xml", xml))
    }

    @Test
    fun serviceListWithoutAvTransportReturnsNull() {
        val xml = """
            <root><device><friendlyName>TV</friendlyName>
              <serviceList><service>
                <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
                <controlURL>/upnp/control/ContentDir</controlURL>
              </service></serviceList>
            </device></root>
        """.trimIndent()
        assertNull(DlnaDeviceDescription.parse("u", "http://h/desc.xml", xml))
    }

    @Test
    fun avTransportWithoutControlUrlReturnsNull() {
        val xml = """
            <root><device><friendlyName>TV</friendlyName>
              <serviceList><service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
              </service></serviceList>
            </device></root>
        """.trimIndent()
        assertNull(DlnaDeviceDescription.parse("u", "http://h/desc.xml", xml))
    }

    @Test
    fun relativeControlUrlResolvesAgainstLocation() {
        val xml = deviceXml.replace("/upnp/control/AVTransport1", "ctl/AVTransport1")
        val device = DlnaDeviceDescription.parse("u", "http://10.0.0.5:1234/desc.xml", xml)
        assertNotNull(device)
        assertEquals("http://10.0.0.5:1234/ctl/AVTransport1", device.controlUrl)
    }

    @Test
    fun absoluteControlUrlPassesThrough() {
        val xml = deviceXml.replace("/upnp/control/AVTransport1", "http://other:9999/ctl")
        val device = DlnaDeviceDescription.parse("u", "http://10.0.0.5:1234/desc.xml", xml)
        assertNotNull(device)
        assertEquals("http://other:9999/ctl", device.controlUrl)
    }

    @Test
    fun resolveUrlHandlesHttpsAndPorts() {
        assertEquals(
            "https://10.0.0.5:8443/upnp/control/AVT",
            DlnaDeviceDescription.resolveUrl("https://10.0.0.5:8443/desc.xml", "/upnp/control/AVT"),
        )
        assertEquals(
            "http://10.0.0.5/upnp/control/AVT",
            DlnaDeviceDescription.resolveUrl("http://10.0.0.5/desc.xml", "/upnp/control/AVT"),
        )
        assertEquals(
            "http://10.0.0.5:1234/ctl",
            DlnaDeviceDescription.resolveUrl("http://10.0.0.5:1234/desc.xml", "ctl"),
        )
    }
}
