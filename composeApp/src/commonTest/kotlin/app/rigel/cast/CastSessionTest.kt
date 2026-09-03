package app.rigel.cast

import app.rigel.cast.DlnaDevice
import app.rigel.cast.KodiDevice
import app.rigel.cast.RokuDevice
import app.rigel.source.jellyfin.JellyfinSession
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CastSessionTest {

    private val session = CastSession()

    @Test
    fun dlnaSupportsSeekAndPosition() {
        val caps = session.capabilities(
            CastTarget.Dlna(DlnaDevice("u1", "http://h/desc.xml", "TV", "/ctl")),
        )
        assertTrue(caps.supportsSeek)
        assertTrue(caps.supportsPosition)
        assertEquals(null, caps.note)
    }

    @Test
    fun rokuHasNoSeekOrPositionAndExplains() {
        val caps = session.capabilities(CastTarget.Roku(RokuDevice("r1", "http://h:8060/", "Roku")))
        assertFalse(caps.supportsSeek)
        assertFalse(caps.supportsPosition)
        assertEquals("Roku ECP media playback has no seek or position tracking", caps.note)
    }

    @Test
    fun kodiSupportsSeekAndPosition() {
        val caps = session.capabilities(CastTarget.Kodi(KodiDevice("k1", "http://h:8080", "Kodi")))
        assertTrue(caps.supportsSeek)
        assertTrue(caps.supportsPosition)
        assertEquals(null, caps.note)
    }

    @Test
    fun jellyfinSessionHasNoSeekOrPositionAndExplains() {
        val caps = session.capabilities(CastTarget.JellyfinSessionTarget(JellyfinSession("j1", "iPhone", "Jellyfin")))
        assertFalse(caps.supportsSeek)
        assertFalse(caps.supportsPosition)
        assertEquals("Jellyfin session remote control plays library items; no seek/position", caps.note)
    }

    @Test
    fun targetNamesFromDevices() {
        assertEquals("TV", CastTarget.Dlna(DlnaDevice("u1", "http://h/desc.xml", "TV", "/ctl")).name)
        assertEquals("Roku Ultra", CastTarget.Roku(RokuDevice("r1", "http://h:8060/", "Roku Ultra")).name)
        assertEquals("Roku", CastTarget.Roku(RokuDevice("r1", "http://h:8060/", null)).name)
        assertEquals("Kodi Box", CastTarget.Kodi(KodiDevice("k1", "http://h:8080", "Kodi Box")).name)
        assertEquals("Kodi", CastTarget.Kodi(KodiDevice("k1", "http://h:8080", null)).name)
        assertEquals("iPhone", CastTarget.JellyfinSessionTarget(JellyfinSession("j1", "iPhone", "Jellyfin")).name)
    }
}
