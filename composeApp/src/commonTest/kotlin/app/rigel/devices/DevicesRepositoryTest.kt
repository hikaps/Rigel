package app.rigel.devices

import app.rigel.bridge.DiscoveryBridge
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastTarget
import app.rigel.cast.chrome.CastWireConnection
import app.rigel.cast.chrome.ChromeDevice
import app.rigel.cast.chrome.ChromecastBridge
import app.rigel.cast.chrome.ChromecastBridgeFactory
import app.rigel.settings.SettingsStore
import com.russhwolf.settings.MapSettings
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DevicesRepositoryTest {

    private class FakeDiscovery(var devices: List<SsdpDevice> = emptyList()) : DiscoveryBridge {
        override fun ssdpSearch(
            searchTargets: List<String>,
            timeoutMs: Int,
            onResult: (List<SsdpDevice>) -> Unit,
        ) {
            onResult(devices)
        }
    }

    private class FakeChromecastBridge(var devices: List<ChromeDevice> = emptyList()) : ChromecastBridge {
        override fun discover(timeoutMs: Int, onResult: (List<ChromeDevice>) -> Unit) {
            onResult(devices)
        }

        override fun open(
            host: String,
            port: Int,
            onFrame: (ByteArray) -> Unit,
            onError: (String) -> Unit,
            onOpen: (CastWireConnection?, String?) -> Unit,
        ) {
            onOpen(null, "not implemented in repository scan tests")
        }
    }

    private val discovery = FakeDiscovery()

    private val deviceInfoXml = """
        <device-info>
          <has-play-on-roku>true</has-play-on-roku>
          <model-name>Roku Ultra</model-name>
        </device-info>
    """.trimIndent()

    private val dlnaXml = """
        <root><device>
          <friendlyName>Living Room TV</friendlyName>
          <serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/upnp/control/AVTransport1</controlURL>
          </service></serviceList>
        </device></root>
    """.trimIndent()

    private fun repo(
        engine: MockEngine,
        settings: SettingsStore,
        chrome: ChromecastBridge? = null,
    ): DevicesRepository {
        ChromecastBridgeFactory.register(chrome)
        RigelBridgeFactory.register(discovery = discovery, probe = null, transcode = null, httpServer = null)
        return DevicesRepository(HttpClient(engine), settings)
    }

    @Test
    fun scanFindsRokuViaSsdp() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            when (request.url.encodedPath) {
                "/query/device-info" -> respond(deviceInfoXml, HttpStatusCode.OK)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        discovery.devices = listOf(
            SsdpDevice("usn-r1", "http://10.0.0.7:8060/", "Roku", "roku:ecp"),
        )
        val found = repo(engine, SettingsStore(MapSettings(mutableMapOf()))).scan()
        assertEquals(1, found.size)
        val device = found[0]
        assertEquals("ssdp", device.via)
        assertIs<CastTarget.Roku>(device.target)
        assertEquals("Roku Ultra", device.target.name)
    }

    @Test
    fun scanDetectsKodiAlongsideMediaRenderer() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            if (request.url.encodedPath == "/jsonrpc") respond("", HttpStatusCode.OK)
            else respond("", HttpStatusCode.NotFound)
        }
        discovery.devices = listOf(
            SsdpDevice("usn-k1", "http://10.0.0.5:1234/desc.xml", "Kodi", "urn:schemas-upnp-org:device:MediaRenderer:1"),
        )
        val found = repo(engine, SettingsStore(MapSettings(mutableMapOf()))).scan()
        assertEquals(1, found.size)
        assertIs<CastTarget.Kodi>(found[0].target)
        assertEquals("http://10.0.0.5:8080", (found[0].target as CastTarget.Kodi).device.endpoint)
    }

    @Test
    fun scanEnrichesDlnaFromMediaRenderer() = kotlinx.coroutines.test.runTest {
        // DlnaAdapter.fromSsdp fetches the location XML for live MediaRenderer responses
        // (was previously broken — only manual 'dlna' pseudo-target enriched).
        val engine = MockEngine { request ->
            when (request.url.encodedPath) {
                "/desc.xml" -> respond(dlnaXml, HttpStatusCode.OK)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        discovery.devices = listOf(
            SsdpDevice("usn-d1", "http://10.0.0.5:1234/desc.xml", "TV", "urn:schemas-upnp-org:device:MediaRenderer:1"),
        )
        val found = repo(engine, SettingsStore(MapSettings(mutableMapOf()))).scan()
        assertEquals(1, found.size)
        assertIs<CastTarget.Dlna>(found[0].target)
        assertEquals("Living Room TV", found[0].target.name)
    }
    @Test
    fun scanFindsChromecastViaMdnsBridge() = kotlinx.coroutines.test.runTest {
        discovery.devices = emptyList()
        val chrome = FakeChromecastBridge(
            listOf(ChromeDevice("c1", "192.168.1.50", 8009, "Living Room TV")),
        )
        val found = repo(
            MockEngine { respond("", HttpStatusCode.NotFound) },
            SettingsStore(MapSettings(mutableMapOf())),
            chrome,
        ).scan()

        assertEquals(1, found.size)
        assertEquals("mdns", found.single().via)
        assertIs<CastTarget.Chrome>(found.single().target)
        assertEquals("Living Room TV", found.single().target.name)
    }

    @Test
    fun scanRehydratesChromecastManualRow() = kotlinx.coroutines.test.runTest {
        discovery.devices = emptyList()
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.addManualDevice("chrome|c1|192.168.1.50:8009|Living Room TV")

        val found = repo(
            MockEngine { respond("", HttpStatusCode.NotFound) },
            settings,
        ).scan()

        assertEquals(1, found.size)
        assertEquals("manual", found.single().via)
        assertEquals("c1", (found.single().target as CastTarget.Chrome).device.id)
    }


    @Test
    fun scanAddsManualDevices() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            when (request.url.encodedPath) {
                "/desc.xml" -> respond(dlnaXml, HttpStatusCode.OK)
                "/query/device-info" -> respond(deviceInfoXml, HttpStatusCode.OK)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.addManualDevice("kodi|mk1|http://10.0.0.9:8080|Kodi")
        settings.addManualDevice("dlna|md1|http://10.0.0.5:1234/desc.xml|TV")
        settings.addManualDevice("roku|mr1|http://10.0.0.7:8060/|Roku")
        val found = repo(engine, settings).scan()
        assertEquals(3, found.size)
        assertTrue(found.all { it.via == "manual" })
        assertEquals(listOf("Kodi", "Living Room TV", "Roku Ultra"), found.map { it.target.name })
    }

    @Test
    fun scanSkipsMalformedAndUnknownManualRows() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.NotFound) }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.addManualDevice("too|short")
        settings.addManualDevice("banana|a|b|c")
        val found = repo(engine, settings).scan()
        assertTrue(found.isEmpty())
    }

    @Test
    fun scanDeduplicatesManualAgainstSsdpByName() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            if (request.url.encodedPath == "/jsonrpc") respond("", HttpStatusCode.OK)
            else respond("", HttpStatusCode.NotFound)
        }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.addManualDevice("kodi|mk1|http://10.0.0.9:8080|Kodi")
        discovery.devices = listOf(
            SsdpDevice("usn-k1", "http://10.0.0.5:1234/desc.xml", "Kodi", "urn:schemas-upnp-org:device:MediaRenderer:1"),
        )
        val found = repo(engine, settings).scan()
        assertEquals(1, found.size)
    }

    @Test
    fun addManualByIpDetectsKodi() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            if (request.url.encodedPath == "/jsonrpc") respond("", HttpStatusCode.OK)
            else respond("", HttpStatusCode.NotFound)
        }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val target = repo(engine, settings).addManualByIp("10.0.0.9")
        assertNotNull(target)
        assertIs<CastTarget.Kodi>(target)
        assertEquals(
            listOf("kodi|manual-kodi-10.0.0.9|http://10.0.0.9:8080|Kodi"),
            settings.manualDevices(),
        )
    }

    @Test
    fun addManualByIpDetectsDlna() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            when (request.url.encodedPath) {
                "/jsonrpc" -> respond("", HttpStatusCode.NotFound)
                "/rootDesc.xml" -> respond(dlnaXml, HttpStatusCode.OK)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val target = repo(engine, settings).addManualByIp("10.0.0.5")
        assertNotNull(target)
        assertIs<CastTarget.Dlna>(target)
        assertTrue(settings.manualDevices().any { it.startsWith("dlna|manual-dlna-10.0.0.5|") })
    }

    @Test
    fun addManualByIpDetectsRoku() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            when (request.url.encodedPath) {
                "/jsonrpc" -> respond("", HttpStatusCode.NotFound)
                "/rootDesc.xml" -> respond("", HttpStatusCode.NotFound)
                "/query/device-info" -> respond(deviceInfoXml, HttpStatusCode.OK)
                else -> respond("", HttpStatusCode.NotFound)
            }
        }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val target = repo(engine, settings).addManualByIp("10.0.0.7")
        assertNotNull(target)
        assertIs<CastTarget.Roku>(target)
        assertTrue(settings.manualDevices().any { it.startsWith("roku|manual-roku-10.0.0.7|") })
    }

    @Test
    fun addManualByIpReturnsNullWhenUnreachable() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.NotFound) }
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val target = repo(engine, settings).addManualByIp("10.0.0.254")
        assertNull(target)
        assertTrue(settings.manualDevices().isEmpty())
    }

    @Test
    fun addManualByIpRejectsBlank() = kotlinx.coroutines.test.runTest {
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        assertNull(repo(MockEngine { respond("", HttpStatusCode.OK) }, settings).addManualByIp("  "))
    }

    @Test
    fun removeManualDeviceDelegatesToSettings() = kotlinx.coroutines.test.runTest {
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.addManualDevice("kodi|mk1|http://10.0.0.9:8080|Kodi")
        val target = CastTarget.Kodi(app.rigel.cast.kodi.KodiDevice("mk1", "http://10.0.0.9:8080", "Kodi"))
        repo(MockEngine { respond("", HttpStatusCode.OK) }, settings).removeManualDevice(target)
        assertTrue(settings.manualDevices().isEmpty())
    }
}
