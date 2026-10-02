package app.rigel.source.jellyfin

import io.ktor.http.Url
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class JellyfinApiTest {

    @Test
    fun authBodyEscapes() {
        assertEquals("""{"Username":"a\"b","Pw":"pw"}""", JellyfinApi.authBody("""a"b""", "pw"))
    }
    @Test
    fun authBodyEscapesJsonControlCharacters() {
        val username = "\"\\\b\t\n\u0000\u001F"
        val password = "\r\u000C"
        val expected = """{"Username":"\"\\\b\t\n""" +
            "\\" + "u0000" + "\\" + "u001F" +
            """","Pw":"\r\f"}"""
        assertEquals(expected, JellyfinApi.authBody(username, password))
    }

    @Test
    fun authBodyEscapesAdditionalJsonControlCharacter() {
        assertEquals(
            """{"Username":"\u0001\n\r\t\b\f","Pw":"pw"}""",
            JellyfinApi.authBody("\u0001\n\r\t\b\u000C", "pw"),
        )
    }

    @Test
    fun embyAuthHeaderFormat() {
        val header = JellyfinApi.embyAuthHeader("dev-123")
        assertEquals(
            """MediaBrowser Client="Rigel", Device="Rigel iOS", DeviceId="dev-123", Version="1.0"""",
            header,
        )
    }

    @Test
    fun browseUrlWithAndWithoutParent() {
        assertEquals(
            "http://jf:8096/Items?UserId=u1&Recursive=false&StartIndex=0&Limit=50&EnableTotalRecordCount=true&EnableImages=false&SortBy=SortName&SortOrder=Ascending",
            JellyfinApi.browseUrl("http://jf:8096/", "u1", null, 0, 50, JellyfinBrowseOrder.NAME),
        )
        assertEquals(
            "http://jf:8096/Items?UserId=u1&Recursive=false&ParentId=root&StartIndex=0&Limit=50&EnableTotalRecordCount=true&EnableImages=false&SortBy=SortName&SortOrder=Ascending",
            JellyfinApi.browseUrl("http://jf:8096", "u1", "root", 0, 50, JellyfinBrowseOrder.NAME),
        )
    }

    @Test
    fun searchUrlQueriesJellyfinAndEncodesTerm() {
        assertEquals(
            "http://jf:8096/Items?UserId=u1&Recursive=true&SearchTerm=star%20wars&IncludeItemTypes=Movie,Series,Episode,Video&StartIndex=0&Limit=50&EnableTotalRecordCount=true&EnableImages=false",
            JellyfinApi.searchUrl("http://jf:8096/", "u1", "star wars", JellyfinSearchFilter.ALL, 0, 50),
        )
    }

    @Test
    fun streamUrlSelectsAndEncodesMediaSource() {
        assertEquals(
            "https://jf/proxy/Videos/i%2F42/stream?Static=true&MediaSourceId=ms%2Fhi&api_key=tok%20%26",
            JellyfinApi.streamUrl("https://jf/proxy/", "i/42", "tok &", "ms/hi"),
        )
    }

    @Test
    fun tokenizedJellyfinStreamDetectionRequiresItsRouteAndApiKey() {
        assertTrue(JellyfinApi.isTokenizedJellyfinStream("https://jf/Videos/i1/stream?Static=true&api_key=secret"))
        assertTrue(JellyfinApi.isTokenizedJellyfinStream("https://jf/Videos/i1/stream?Static=true&api%5Fkey=secret"))
        assertTrue(JellyfinApi.isTokenizedJellyfinStream("https://jf/Videos/i1/stream?Static=true&API_KEY=secret"))
        assertTrue(!JellyfinApi.isTokenizedJellyfinStream("https://jf/Videos/i1/stream?Static=true"))
        assertTrue(!JellyfinApi.isTokenizedJellyfinStream("https://jf/Items/i1?api_key=secret"))
    }
    @Test
    fun playUrlEncodesSessionItemsAndParameters() {
        assertEquals(
            "http://jf:8096/Sessions/s%2F1/Playing?playCommand=PlayNow&itemIds=a%20b,c%2Fd&startPositionTicks=42",
            JellyfinApi.playUrl(
                base = "http://jf:8096/",
                sessionId = "s/1",
                itemIds = listOf("a b", "c/d"),
                startPositionTicks = 42,
            ),
        )
    }
    @Test
    fun playUrlCarriesEncodedSelectedSource() {
        assertEquals(
            "http://jf:8096/Sessions/s1/Playing?playCommand=PlayNow&itemIds=item1&startPositionTicks=0&mediaSourceId=version%2F2",
            JellyfinApi.playUrl(
                base = "http://jf:8096",
                sessionId = "s1",
                itemIds = listOf("item1"),
                mediaSourceId = "version/2",
            ),
        )
    }

    @Test
    fun stopSessionUrlEncodesSessionIdAsOnePathComponent() {
        assertEquals(
            "http://jf:8096/emby/Sessions/s%2F1%3Fnext%3D%23%25/Playing/Stop",
            JellyfinApi.stopSessionUrl("http://jf:8096/emby/", "s/1?next=#%"),
        )
    }

    @Test
    fun stopSessionUrlPreservesOpaqueSessionId() {
        assertEquals(
            "http://jf:8096/Sessions/session-123_abc/Playing/Stop",
            JellyfinApi.stopSessionUrl("http://jf:8096", "session-123_abc"),
        )
    }

    @Test
    fun browseUrlSkipsBlankParentId() {
        assertEquals(
            "http://jf:8096/Items?UserId=u1&Recursive=false&StartIndex=0&Limit=50&EnableTotalRecordCount=true&EnableImages=false&SortBy=SortName&SortOrder=Ascending",
            JellyfinApi.browseUrl("http://jf:8096", "u1", "", 0, 50, JellyfinBrowseOrder.NAME),
        )
    }

    @Test
    fun embyAuthHeaderCustomValues() {
        assertEquals(
            """MediaBrowser Client="C", Device="D", DeviceId="dev", Version="9.9"""",
            JellyfinApi.embyAuthHeader("dev", client = "C", device = "D", version = "9.9"),
        )
    }

    @Test
    fun normalizeServerBasePreservesIpv6AuthorityBrackets() {
        assertEquals("http://[::1]:8096", JellyfinApi.normalizeServerBase("http://[::1]:8096/"))
        assertEquals("https://[2001:db8::1]/jellyfin", JellyfinApi.normalizeServerBase("HTTPS://[2001:DB8::1]/jellyfin/"))
    }
    @Test
    fun pagedBrowseUrlEncodesIdentityAndOrdersEpisodes() {
        assertEquals(
            "http://jf:8096/Items?UserId=u%2F1&Recursive=false&ParentId=root%2F1&StartIndex=50&Limit=50&EnableTotalRecordCount=true&EnableImages=false&SortBy=ParentIndexNumber%2CIndexNumber%2CSortName&SortOrder=Ascending",
            JellyfinApi.browseUrl("http://jf:8096/", "u/1", "root/1", 50, 50, JellyfinBrowseOrder.EPISODE),
        )
    }

    @Test
    fun filteredSearchUrlEncodesTermAndRequestsPage() {
        assertEquals(
            "http://jf:8096/Items?UserId=u1&Recursive=true&SearchTerm=Am%C3%A9lie%20%26%20friends&IncludeItemTypes=Movie&StartIndex=50&Limit=50&EnableTotalRecordCount=true&EnableImages=false",
            JellyfinApi.searchUrl("http://jf:8096/", "u1", "Amélie & friends", JellyfinSearchFilter.MOVIES, 50, 50),
        )
    }
    @Test
    fun itemDetailsUrlUsesCurrentItemRouteAndEncodesIdentifiers() {
        assertEquals(
            "https://jf/proxy/Items/item%2F1?UserId=user%2F1&Fields=MediaStreams,MediaSources",
            JellyfinApi.itemDetailsUrl("https://jf/proxy/", "user/1", "item/1"),
        )
    }
    @Test
    fun playbackInfoRequestUsesSelectedMediaSourceAndLocalHlsCapabilities() {
        val body = JellyfinApi.playbackInfoBody("user-1", "source-2")
        val root = mutableMapOf<String, String>()
        val direct = mutableListOf<Map<String, String>>()
        val transcoding = mutableListOf<Map<String, String>>()
        val subtitles = mutableListOf<Map<String, String>>()
        JsonObjectReader(body, onObjectAtPath = { path, fields ->
            when (path) {
                emptyList<String>() -> root.putAll(fields)
                listOf("DeviceProfile", "DirectPlayProfiles", "0") -> direct += fields
                listOf("DeviceProfile", "TranscodingProfiles", "0") -> transcoding += fields
                listOf("DeviceProfile", "SubtitleProfiles", "0") -> subtitles += fields
            }
        }).parseObjectsWithPaths()

        assertEquals("user-1", root["UserId"])
        assertEquals("source-2", root["MediaSourceId"])
        assertEquals("true", root["IsPlayback"])
        assertEquals("true", root["AutoOpenLiveStream"])
        assertEquals("true", root["EnableDirectPlay"])
        assertEquals("true", root["EnableDirectStream"])
        assertEquals("true", root["EnableTranscoding"])
        assertEquals(1, direct.size)
        assertEquals("Video", direct.single()["Type"])
        assertTrue("mp4" in direct.single().getValue("Container").split(','))
        assertFalse("mkv" in direct.single().getValue("Container").split(','))
        assertTrue("h264" in direct.single().getValue("VideoCodec").split(','))
        assertTrue("aac" in direct.single().getValue("AudioCodec").split(','))
        assertEquals("hls", transcoding.single()["Protocol"])
        assertEquals("ts", transcoding.single()["Container"])
        assertEquals("h264", transcoding.single()["VideoCodec"])
        assertEquals("aac", transcoding.single()["AudioCodec"])
        assertEquals("vtt", subtitles.single()["Format"])
        assertEquals("Hls", subtitles.single()["Method"])
    }

    @Test
    fun playbackAndStopUrlsUseJellyfinRoutes() {
        assertEquals(
            "https://jf/proxy/Items/item%2F1/PlaybackInfo",
            JellyfinApi.playbackInfoUrl("https://jf/proxy/", "item/1"),
        )
        val stop = Url(JellyfinApi.stopPlaybackUrl("https://jf/proxy", "play session/&"))
        assertEquals("/proxy/Videos/ActiveEncodings", stop.encodedPath)
        assertEquals(setOf("DeviceId", "PlaySessionId"), stop.parameters.names())
        assertEquals("rigel-ios", stop.parameters["DeviceId"])
        assertEquals("play session/&", stop.parameters["PlaySessionId"])
    }

    @Test
    fun negotiatedPlaybackUrlsResolveWithinServerMountAndPreserveSessionQuery() {
        val relative = JellyfinApi.resolvePlaybackUrl(
            "https://jf/proxy/", "Videos/item/master.m3u8?PlaySessionId=ps-1&MediaSourceId=source-2", "current token",
        ) ?: error("relative playback URL should resolve")
        val relativeUrl = Url(relative)
        assertEquals("/proxy/Videos/item/master.m3u8", relativeUrl.encodedPath)
        assertEquals("ps-1", relativeUrl.parameters["PlaySessionId"])
        assertEquals("source-2", relativeUrl.parameters["MediaSourceId"])
        assertEquals("current token", relativeUrl.parameters["api_key"])

        val rootRelative = JellyfinApi.resolvePlaybackUrl(
            "https://jf/proxy", "/Videos/item/master.m3u8?PlaySessionId=ps-1", "tok",
        ) ?: error("root-relative playback URL should resolve")
        assertEquals("/proxy/Videos/item/master.m3u8", Url(rootRelative).encodedPath)

        val alreadyMounted = JellyfinApi.resolvePlaybackUrl(
            "https://jf/proxy", "/proxy/Videos/item/master.m3u8?PlaySessionId=ps-1", "tok",
        ) ?: error("already-mounted playback URL should resolve")
        assertEquals("/proxy/Videos/item/master.m3u8", Url(alreadyMounted).encodedPath)

        val absolute = JellyfinApi.resolvePlaybackUrl(
            "https://jf/proxy", "https://jf:443/proxy/Videos/item/stream?PlaySessionId=ps-2&MediaSourceId=source-4&ApiKey=old&apikey=stale&api_key=older", "fresh",
        ) ?: error("same-origin mounted absolute playback URL should resolve")
        val absoluteUrl = Url(absolute)
        assertEquals("/proxy/Videos/item/stream", absoluteUrl.encodedPath)
        assertEquals("ps-2", absoluteUrl.parameters["PlaySessionId"])
        assertEquals("source-4", absoluteUrl.parameters["MediaSourceId"])
        assertEquals(listOf("fresh"), absoluteUrl.parameters.getAll("api_key"))
        assertEquals(
            setOf("api_key"),
            absoluteUrl.parameters.names().filter { it.equals("api_key", true) || it.equals("apikey", true) }.toSet(),
        )
    }

    @Test
    fun sameOriginAbsolutePlaybackUrlCannotEscapeConfiguredMount() {
        for (candidate in listOf(
            "https://jf/Videos/item/stream?PlaySessionId=ps",
            "https://jf/proxy-escape/Videos/item/stream?PlaySessionId=ps",
            "//jf/Videos/item/stream?PlaySessionId=ps",
        )) {
            assertNull(JellyfinApi.resolvePlaybackUrl("https://jf/proxy", candidate, "secret"), candidate)
        }
    }

    @Test
    fun playbackUrlRejectsForeignOriginsCredentialsAndMalformedPaths() {
        for (candidate in listOf(
            "https://evil.example/Videos/item/stream?PlaySessionId=ps",
            "https://user@jf/Videos/item/stream?PlaySessionId=ps",
            "//evil.example/Videos/item/stream?PlaySessionId=ps",
            "/Videos/%2e%2e/private/stream",
            "/Videos/%GG/stream",
            "?PlaySessionId=ps",
            "../../../private/stream",
            "javascript:alert(1)",
        )) {
            assertNull(JellyfinApi.resolvePlaybackUrl("https://jf/proxy", candidate, "secret"), candidate)
        }
    }
}
