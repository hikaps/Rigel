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
    fun dlnaSupportsFullRemoteControl() {
        val caps = session.capabilities(
            CastTarget.Dlna(DlnaDevice("u1", "http://h/desc.xml", "TV", "/ctl")),
        )
        assertTrue(caps.supportsSeek)
        assertTrue(caps.supportsPosition)
        assertTrue(caps.supportsPauseResume)
        assertTrue(caps.supportsStop)
        assertTrue(caps.supportsVolume)
        assertEquals(null, caps.note)
    }

    @Test
    fun rokuHasRemoteControlButNoSeekOrPositionAndExplains() {
        val caps = session.capabilities(CastTarget.Roku(RokuDevice("r1", "http://h:8060/", "Roku")))
        assertFalse(caps.supportsSeek)
        assertFalse(caps.supportsPosition)
        assertTrue(caps.supportsPauseResume)
        assertTrue(caps.supportsStop)
        assertTrue(caps.supportsVolume)
        assertEquals("Roku ECP playback: remote control with relative volume, no seek or position", caps.note)
    }

    @Test
    fun kodiSupportsFullRemoteControl() {
        val caps = session.capabilities(CastTarget.Kodi(KodiDevice("k1", "http://h:8080", "Kodi")))
        assertTrue(caps.supportsSeek)
        assertTrue(caps.supportsPosition)
        assertTrue(caps.supportsPauseResume)
        assertTrue(caps.supportsStop)
        assertTrue(caps.supportsVolume)
        assertEquals(null, caps.note)
    }

    @Test
    fun jellyfinSessionHasNoRemoteControlAndExplains() {
        val caps = session.capabilities(CastTarget.JellyfinSessionTarget(JellyfinSession("j1", "iPhone", "Jellyfin")))
        assertFalse(caps.supportsSeek)
        assertFalse(caps.supportsPosition)
        assertFalse(caps.supportsPauseResume)
        assertFalse(caps.supportsStop)
        assertFalse(caps.supportsVolume)
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
