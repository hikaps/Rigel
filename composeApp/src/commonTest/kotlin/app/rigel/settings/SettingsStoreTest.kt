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

    private class FakeJellyfinTokenStore(
        private var stored: String? = null,
        private val writesSucceed: Boolean = true,
        private val clearsSucceed: Boolean = true,
    ) : JellyfinTokenStore {
        override val persistsAcrossInstances = true
        var writeAttempts = 0
            private set
        var clearAttempts = 0
            private set

        override fun read(): String? = stored

        override fun write(value: String): Boolean {
            writeAttempts++
            if (!writesSucceed) return false
            stored = value
            return true
        }

        override fun clear(): Boolean {
            clearAttempts++
            if (!clearsSucceed) return false
            stored = null
            return true
        }
    }

    private fun store(
        settings: MapSettings = MapSettings(mutableMapOf()),
        tokenStore: JellyfinTokenStore = FakeJellyfinTokenStore(),
    ): SettingsStore {
        return SettingsStore(settings, tokenStore)
    }

    @Test
    fun jellyfinFieldsDefaultEmptyAndRoundTrip() {
        val s = store()
        assertEquals("", s.jellyfinServer())
        assertEquals("", s.jellyfinToken())
        assertEquals("", s.jellyfinUserId())
        assertEquals("", s.jellyfinUsername())

        s.setJellyfinServer("http://jf:8096")
        assertTrue(s.setJellyfinToken("tok"))
        s.setJellyfinUserId("u1")
        s.setJellyfinUsername("alice")
        assertEquals("http://jf:8096", s.jellyfinServer())
        assertEquals("tok", s.jellyfinToken())
        assertEquals("u1", s.jellyfinUserId())
        assertEquals("alice", s.jellyfinUsername())
    }

    @Test
    fun defaultTokenStoresAreIsolatedPerSettingsInstance() {
        val first = SettingsStore(MapSettings(mutableMapOf()))
        val second = SettingsStore(MapSettings(mutableMapOf()))

        assertTrue(first.setJellyfinToken("first-token"))
        assertEquals("first-token", first.jellyfinToken())
        assertEquals("", second.jellyfinToken())
    }
    @Test
    fun volatileDefaultTokenStoreKeepsLegacyCredentialAcrossInstances() {
        val settings = MapSettings(mutableMapOf())
        settings.putString("jellyfin_token", "legacy-token")

        val first = SettingsStore(settings)
        assertEquals("legacy-token", first.jellyfinToken())
        assertTrue(first.setJellyfinToken("volatile-token"))
        assertEquals("volatile-token", first.jellyfinToken())

        val second = SettingsStore(settings)
        assertEquals("legacy-token", second.jellyfinToken())
    }

    @Test
    fun jellyfinTokenMigrationRemovesPlaintextOnlyAfterSecureWrite() {
        val settings = MapSettings(mutableMapOf())
        settings.putString("jellyfin_token", "legacy-token")
        val tokenStore = FakeJellyfinTokenStore(writesSucceed = true)

        val s = store(settings, tokenStore)

        assertEquals("legacy-token", s.jellyfinToken())
        assertEquals("", settings.getString("jellyfin_token", ""))
        assertEquals(1, tokenStore.writeAttempts)
    }

    @Test
    fun jellyfinTokenMigrationKeepsPlaintextWhenSecureWriteFails() {
        val settings = MapSettings(mutableMapOf())
        settings.putString("jellyfin_token", "legacy-token")
        val tokenStore = FakeJellyfinTokenStore(writesSucceed = false)

        val s = store(settings, tokenStore)

        assertEquals("legacy-token", s.jellyfinToken())
        assertEquals("legacy-token", settings.getString("jellyfin_token", ""))
        assertEquals(1, tokenStore.writeAttempts)
    }

    @Test
    fun disconnectClearsSecureToken() {
        val tokenStore = FakeJellyfinTokenStore(stored = "secure-token")
        val s = store(tokenStore = tokenStore)

        assertTrue(s.setJellyfinToken(""))

        assertEquals("", s.jellyfinToken())
        assertEquals(1, tokenStore.clearAttempts)
    }

    @Test
    fun secureWriteFailurePreservesExistingLogicalCredential() {
        val settings = MapSettings(mutableMapOf())
        settings.putString("jellyfin_token", "legacy-token")
        val tokenStore = FakeJellyfinTokenStore(writesSucceed = false)
        val s = store(settings, tokenStore)

        assertFalse(s.setJellyfinToken("new-token"))
        assertEquals("legacy-token", s.jellyfinToken())
        assertEquals("legacy-token", settings.getString("jellyfin_token", ""))
    }

    @Test
    fun secureClearFailurePreservesExistingLogicalCredential() {
        val tokenStore = FakeJellyfinTokenStore(stored = "secure-token", clearsSucceed = false)
        val s = store(tokenStore = tokenStore)

        assertFalse(s.setJellyfinToken(""))
        assertEquals("secure-token", s.jellyfinToken())
        assertEquals(1, tokenStore.clearAttempts)
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
    fun linkHistoryRedactsCredentialQueryValuesAndLegacyRows() {
        val settings = MapSettings(mutableMapOf())
        settings.putString(
            "link_history",
            "Legacy|https://jf.example/items/1?api_key=old-secret&foo=bar&access_token=also-secret#play",
        )
        val s = store(settings)

        assertEquals(
            listOf(LinkHistoryEntry("https://jf.example/items/1?foo=bar#play", "Legacy")),
            s.linkHistory(),
        )
        val persisted = settings.getString("link_history", "")
        assertFalse(persisted.contains("api_key"))
        assertFalse(persisted.contains("old-secret"))
        assertFalse(persisted.contains("access_token"))
        assertFalse(persisted.contains("also-secret"))
        assertTrue(persisted.contains("foo=bar"))
    }

    @Test
    fun linkHistoryRedactsPercentEncodedCredentialQueryNames() {
        val settings = MapSettings(mutableMapOf())
        settings.putString(
            "link_history",
            "Encoded|https://jf.example/items/1?api%5Fkey=old-secret&access%5Ftoken=also-secret&quality=full",
        )

        val s = store(settings)

        assertEquals(
            listOf(LinkHistoryEntry("https://jf.example/items/1?quality=full", "Encoded")),
            s.linkHistory(),
        )
        val persisted = settings.getString("link_history", "")
        assertFalse(persisted.contains("old-secret"))
        assertFalse(persisted.contains("also-secret"))
        assertFalse(persisted.contains("api%5Fkey"))
        assertFalse(persisted.contains("access%5Ftoken"))
        assertTrue(persisted.contains("quality=full"))
    }

    @Test
    fun linkHistoryPreservesMalformedNonsensitiveQueryNames() {
        val s = store()

        s.addToLinkHistory("https://example.com/video?quality%ZZ=full", null)

        assertEquals(
            listOf(LinkHistoryEntry("https://example.com/video?quality%ZZ=full", null)),
            s.linkHistory(),
        )
    }

    @Test
    fun linkHistoryRedactsCredentialsWhenAddingEntry() {
        val settings = MapSettings(mutableMapOf())
        val s = store(settings)

        s.addToLinkHistory("https://jf.example/video?X-Emby-Token=secret&quality=full", "Video")

        assertEquals(
            listOf(LinkHistoryEntry("https://jf.example/video?quality=full", "Video")),
            s.linkHistory(),
        )
        assertFalse(settings.getString("link_history", "").contains("secret"))
    }

    @Test
    fun linkHistoryLeavesOrdinaryUrlUnchanged() {
        val s = store()
        s.addToLinkHistory("https://example.com/video.mp4?quality=full", "Video")

        assertEquals(
            listOf(LinkHistoryEntry("https://example.com/video.mp4?quality=full", "Video")),
            s.linkHistory(),
        )
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
    @Test
    fun linkHistoryPurgesPreviouslyStoredJellyfinAccessKeys() {
        val values = mutableMapOf<String, Any>(
            "link_history" to "Movie|https://jf/proxy/Videos/i1/stream?Static=true&MediaSourceId=v2&api_key=secret\nWeb|https://media.example/video.mp4",
        )
        val settings = SettingsStore(MapSettings(values))

        assertEquals(listOf(LinkHistoryEntry("https://media.example/video.mp4", "Web")), settings.linkHistory())
        assertFalse((values["link_history"] as? String).orEmpty().contains("secret"))
        settings.addToLinkHistory("https://jf/Videos/i2/stream?api_key=new-secret", "Another movie")
        assertEquals(listOf(LinkHistoryEntry("https://media.example/video.mp4", "Web")), settings.linkHistory())
        assertFalse((values["link_history"] as? String).orEmpty().contains("new-secret"))
    }
}
