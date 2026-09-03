package app.rigel.settings

import app.rigel.cast.CastTarget
import app.rigel.cast.ChromeDevice
import app.rigel.cast.DlnaDevice
import app.rigel.cast.KodiDevice
import app.rigel.cast.RokuDevice
import app.rigel.source.jellyfin.JellyfinSession
import com.russhwolf.settings.MapSettings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SettingsStoreTest {

    private fun store(): SettingsStore {
        val map = MapSettings(mutableMapOf())
        return SettingsStore(map)
    }

    @Test
    fun jellyfinFieldsDefaultEmptyAndRoundTrip() {
        val s = store()
        assertEquals("", s.jellyfinServer())
        assertEquals("", s.jellyfinToken())
        assertEquals("", s.jellyfinUserId())
        assertEquals("", s.jellyfinUsername())

        s.setJellyfinServer("http://jf:8096")
        s.setJellyfinToken("tok")
        s.setJellyfinUserId("u1")
        s.setJellyfinUsername("alice")
        assertEquals("http://jf:8096", s.jellyfinServer())
        assertEquals("tok", s.jellyfinToken())
        assertEquals("u1", s.jellyfinUserId())
        assertEquals("alice", s.jellyfinUsername())
    }

    @Test
    fun routeOverrideDefaultsToAutoAndRoundTrips() {
        val s = store()
        assertEquals(RouteOverride.AUTO, s.routeOverride())
        s.setRouteOverride(RouteOverride.DIRECT)
        assertEquals(RouteOverride.DIRECT, s.routeOverride())
        s.setRouteOverride(RouteOverride.ALWAYS_PROXY)
        assertEquals(RouteOverride.ALWAYS_PROXY, s.routeOverride())
        s.setRouteOverride(RouteOverride.AUTO)
        assertEquals(RouteOverride.AUTO, s.routeOverride())
    }

    @Test
    fun unknownRouteOverrideFallsBackToAuto() {
        val map = MapSettings(mutableMapOf("route_override" to "BOGUS"))
        assertEquals(RouteOverride.AUTO, SettingsStore(map).routeOverride())
    }

    @Test
    fun manualDevicesEmptyByDefaultAndAppend() {
        val s = store()
        assertTrue(s.manualDevices().isEmpty())
        s.addManualDevice("kodi|k1|http://h:8080|Kodi")
        s.addManualDevice("roku|r1|http://h:8060/|Roku")
        assertEquals(listOf("kodi|k1|http://h:8080|Kodi", "roku|r1|http://h:8060/|Roku"), s.manualDevices())
    }

    @Test
    fun manualDevicesDeduplicatedByLocation() {
        val s = store()
        s.addManualDevice("kodi|k1|http://h:8080|Kodi")
        s.addManualDevice("kodi|k2|http://h:8080|Kodi Again")
        assertEquals(listOf("kodi|k1|http://h:8080|Kodi"), s.manualDevices())
    }

    @Test
    fun manualDevicesKeepDifferentLocationsOfSameKind() {
        val s = store()
        s.addManualDevice("kodi|k1|http://h1:8080|Kodi")
        s.addManualDevice("kodi|k2|http://h2:8080|Kodi")
        assertEquals(
            listOf("kodi|k1|http://h1:8080|Kodi", "kodi|k2|http://h2:8080|Kodi"),
            s.manualDevices(),
        )
    }

    @Test
    fun manualDevicesIgnoreBlankRows() {
        val map = MapSettings(mutableMapOf("manual_devices" to "\n\nkodi|k1|http://h:8080|Kodi\n"))
        assertEquals(listOf("kodi|k1|http://h:8080|Kodi"), SettingsStore(map).manualDevices())
    }

    @Test
    fun removeManualDeviceFiltersByKind() {
        val s = store()
        s.addManualDevice("kodi|k1|http://h:8080|Kodi")
        s.addManualDevice("roku|r1|http://h:8060/|Roku")
        s.removeManualDevice(CastTarget.Kodi(KodiDevice("k1", "http://h:8080", "Kodi")))
        assertEquals(listOf("roku|r1|http://h:8060/|Roku"), s.manualDevices())
    }

    @Test
    fun removeManualDeviceHandlesAllKinds() {
        val dlna = CastTarget.Dlna(DlnaDevice("d1", "http://h/desc.xml", "TV", "/ctl"))
        val roku = CastTarget.Roku(RokuDevice("r1", "http://h:8060/", "Roku"))
        val kodi = CastTarget.Kodi(KodiDevice("k1", "http://h:8080", "Kodi"))
        val chrome = CastTarget.Chrome(ChromeDevice("c1", "192.168.1.2", 8009, "Chromecast"))
        val jf = CastTarget.JellyfinSessionTarget(JellyfinSession("j1", "iPhone", "Jellyfin"))
        val s = store()
        for (t in listOf(dlna, roku, kodi, chrome, jf)) {
            s.addManualDevice(manualRow(t))
        }
        assertEquals(5, s.manualDevices().size)
        for (t in listOf(dlna, roku, kodi, chrome, jf)) {
            s.removeManualDevice(t)
        }
        assertTrue(s.manualDevices().isEmpty())
    }
    @Test
    fun linkHistoryEmptyByDefault() {
        assertEquals(emptyList<LinkHistoryEntry>(), store().linkHistory())
    }

    @Test
    fun addToLinkHistoryNewestFirst() {
        val s = store()
        s.addToLinkHistory("http://a", null)
        s.addToLinkHistory("http://b", null)
        assertEquals(
            listOf(
                LinkHistoryEntry("http://b", null),
                LinkHistoryEntry("http://a", null),
            ),
            s.linkHistory(),
        )
    }

    @Test
    fun addToLinkHistoryDeduplicatesMovingToFront() {
        val s = store()
        s.addToLinkHistory("http://a", null)
        s.addToLinkHistory("http://b", null)
        s.addToLinkHistory("http://a", null)
        assertEquals(
            listOf(
                LinkHistoryEntry("http://a", null),
                LinkHistoryEntry("http://b", null),
            ),
            s.linkHistory(),
        )
    }

    @Test
    fun addToLinkHistoryCapsAtFifty() {
        val s = store()
        repeat(60) { index -> s.addToLinkHistory("http://$index", null) }
        assertEquals(50, s.linkHistory().size)
        assertEquals("http://59", s.linkHistory().first().url)
        assertFalse(s.linkHistory().any { it.url == "http://0" })
    }

    @Test
    fun addToLinkHistoryStoresSanitizedTitle() {
        val s = store()
        s.addToLinkHistory("http://h/v.mp4", "Movie | One\n")
        assertEquals(
            listOf(LinkHistoryEntry("http://h/v.mp4", "Movie   One")),
            s.linkHistory(),
        )
    }

    @Test
    fun addToLinkHistoryRoundTripsPipeUrlWithoutTitle() {
        val s = store()
        s.addToLinkHistory("http://h/a|b", null)
        assertEquals(listOf(LinkHistoryEntry("http://h/a|b", null)), s.linkHistory())
    }

    @Test
    fun clearLinkHistoryEmpties() {
        val s = store()
        s.addToLinkHistory("http://a", null)
        s.addToLinkHistory("http://b", null)
        s.clearLinkHistory()
        assertEquals(emptyList<LinkHistoryEntry>(), s.linkHistory())
    }

    private fun manualRow(t: CastTarget): String = when (t) {
        is CastTarget.Dlna -> "dlna|${t.device.usn}|${t.device.location}|${t.device.friendlyName}"
        is CastTarget.Roku -> "roku|${t.device.usn}|${t.device.location}|${t.device.modelName ?: "Roku"}"
        is CastTarget.Kodi -> "kodi|${t.device.usn}|${t.device.endpoint}|${t.device.name ?: "Kodi"}"
        is CastTarget.Chrome -> "chrome|${t.device.id}|${t.device.host}:${t.device.port}|${t.device.name}"
        is CastTarget.JellyfinSessionTarget -> "jellyfin|${t.session.id}|x|${t.session.deviceName}"
    }
}
