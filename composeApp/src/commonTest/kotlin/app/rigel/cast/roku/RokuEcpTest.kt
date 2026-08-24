package app.rigel.cast.roku

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RokuEcpTest {

    @Test
    fun launchBodyEncodesMediaUrl() {
        val body = RokuEcp.launchBody("https://example.com/video with space.mkv")
        assertEquals("t=https%3A%2F%2Fexample.com%2Fvideo%20with%20space.mkv", body)
    }

    @Test
    fun deviceInfoWithPlayOnRokuAccepted() {
        val xml = """<?xml version="1.0" encoding="UTF-8"?>
            <device-info>
              <has-play-on-roku>true</has-play-on-roku>
              <model-name>Roku Ultra</model-name>
            </device-info>"""
        val info = RokuEcp.parseDeviceInfo(xml)
        assertNotNull(info)
        assertTrue(info.hasPlayOnRoku)
        assertEquals("Roku Ultra", info.modelName)
    }

    @Test
    fun deviceInfoWithoutPlayOnRokuRejected() {
        val xml = "<device-info><has-play-on-roku>false</has-play-on-roku></device-info>"
        val info = RokuEcp.parseDeviceInfo(xml)
        assertNotNull(info)
        assertFalse(info.hasPlayOnRoku)
    }

    @Test
    fun nonDeviceInfoXmlIsNull() {
        assertNull(RokuEcp.parseDeviceInfo("<html></html>"))
    }

    @Test
    fun appsParseMapsIdsToNames() {
        val xml = """<apps><app id="15985">Play on Roku</app><app id="2285">Netflix</app></apps>"""
        val apps = RokuEcp.parseApps(xml)
        assertEquals("Play on Roku", apps["15985"])
        assertEquals("Netflix", apps["2285"])
    }

    @Test
    fun appsParseEmptyWhenNoApps() {
        assertEquals(emptyMap(), RokuEcp.parseApps("<apps></apps>"))
    }

    @Test
    fun formEncodeKeepsUnreservedAndEncodesUtf8() {
        assertEquals("abc-_.~", RokuEcp.formEncode("abc-_.~"))
        assertEquals("a%20b%2Fc", RokuEcp.formEncode("a b/c"))
        assertEquals("h%C3%A9llo", RokuEcp.formEncode("héllo"))
        assertEquals("%3A%2F%2F", RokuEcp.formEncode("://"))
    }
}
