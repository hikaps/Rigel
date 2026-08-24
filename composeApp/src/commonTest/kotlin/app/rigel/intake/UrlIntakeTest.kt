package app.rigel.intake

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class UrlIntakeTest {

    @Test
    fun parsesNuvioFormatXCallbackUrl() {
        val raw = "rigel://x-callback-url/play?url=https%3A%2F%2Fx%2Fv.mkv&filename=Movie&sub=https%3A%2F%2Fx%2Fs.vtt"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals("https://x/v.mkv", request.sourceUrl)
        assertEquals("Movie", request.filename)
        assertEquals(listOf("https://x/s.vtt"), request.subtitleUrls)
        assertNull(request.successCallbackUrl)
    }

    @Test
    fun parsesMultipleSubtitles() {
        val raw = "rigel://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4&sub=http%3A%2F%2Fa%2F1.vtt&sub=http%3A%2F%2Fa%2F2.vtt"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals(listOf("http://a/1.vtt", "http://a/2.vtt"), request.subtitleUrls)
    }

    @Test
    fun parsesXSuccess() {
        val raw = "rigel://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4&x-success=http%3A%2F%2Fa%2Fdone"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals("http://a/done", request.successCallbackUrl)
    }

    @Test
    fun plainHttpUrlPassesThrough() {
        val request = UrlIntake.parse("http://example.com/movie.mp4")
        assertNotNull(request)
        assertEquals("http://example.com/movie.mp4", request.sourceUrl)
        assertNull(request.filename)
    }

    @Test
    fun fileUrlPassesThrough() {
        assertNotNull(UrlIntake.parse("file:///tmp/x.mkv"))
    }

    @Test
    fun streamActionAccepted() {
        val raw = "rigel://x-callback-url/stream?url=http%3A%2F%2Fa%2Fv.mp4"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals("http://a/v.mp4", request.sourceUrl)
    }

    @Test
    fun xSourceParsed() {
        val raw = "rigel://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4&x-source=kodi-remote"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals("kodi-remote", request.xSource)
    }

    @Test
    fun unknownActionRejected() {
        assertNull(UrlIntake.parse("rigel://x-callback-url/browse?url=http%3A%2F%2Fa"))
    }

    @Test
    fun garbageReturnsNull() {
        assertNull(UrlIntake.parse("not a url"))
        assertNull(UrlIntake.parse("rigel://x-callback-url/other?url=http%3A%2F%2Fa"))
        assertNull(UrlIntake.parse("rigel://x-callback-url/play"))
        assertNull(UrlIntake.parse("rigel://x-callback-url/play?url=ftp%3A%2F%2Ffoo"))
    }

    @Test
    fun percentDecodeHandlesUtf8AndPlus() {
        assertEquals("a b&c", UrlIntake.percentDecode("a+b%26c"))
        assertEquals("héllo", UrlIntake.percentDecode("h%C3%A9llo"))
    }

    @Test
    fun rigelSchemeIsCaseInsensitive() {
        val raw = "RIGEL://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals("http://a/v.mp4", request.sourceUrl)
    }

    @Test
    fun parseQueryHandlesBareKeysAndRepeats() {
        val parsed = UrlIntake.parseQuery("a=1&a=2&b&c=")
        assertEquals(listOf("1", "2"), parsed["a"])
        assertEquals(listOf(""), parsed["b"])
        assertEquals(listOf(""), parsed["c"])
    }

    @Test
    fun parseQueryIgnoresTrailingAmpersand() {
        assertEquals(emptyMap(), UrlIntake.parseQuery("&"))
    }

    @Test
    fun percentDecodePassesThroughInvalidHex() {
        assertEquals("a%zzb", UrlIntake.percentDecode("a%zzb"))
        assertEquals("%", UrlIntake.percentDecode("%"))
    }

    @Test
    fun nonHttpSubtitlesAreFiltered() {
        val raw = "rigel://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4&sub=ftp%3A%2F%2Fx%2Fs.vtt"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertEquals(emptyList(), request.subtitleUrls)
    }

    @Test
    fun nonHttpSuccessCallbackRejected() {
        val raw = "rigel://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4&x-success=ftp%3A%2F%2Fx%2Fdone"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertNull(request.successCallbackUrl)
    }

    @Test
    fun blankXSourceIsNull() {
        val raw = "rigel://x-callback-url/play?url=http%3A%2F%2Fa%2Fv.mp4&x-source=%20%20"
        val request = UrlIntake.parse(raw)
        assertNotNull(request)
        assertNull(request.xSource)
    }
}
