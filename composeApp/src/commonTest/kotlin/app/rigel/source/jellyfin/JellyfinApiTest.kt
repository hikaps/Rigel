package app.rigel.source.jellyfin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class JellyfinApiTest {

    @Test
    fun authBodyEscapes() {
        assertEquals("""{"Username":"a\"b","Pw":"pw"}""", JellyfinApi.authBody("""a"b""", "pw"))
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
            "http://jf:8096/Users/u1/Items?Recursive=false&Fields=Path",
            JellyfinApi.browseUrl("http://jf:8096/", "u1", null),
        )
        assertEquals(
            "http://jf:8096/Users/u1/Items?Recursive=false&Fields=Path&ParentId=root",
            JellyfinApi.browseUrl("http://jf:8096", "u1", "root"),
        )
    }

    @Test
    fun searchUrlQueriesJellyfinAndEncodesTerm() {
        assertEquals(
            "http://jf:8096/Users/u1/Items?Recursive=true&SearchTerm=star%20wars&IncludeItemTypes=Movie,Series,Episode,Video&Fields=Path",
            JellyfinApi.searchUrl("http://jf:8096/", "u1", "star wars"),
        )
    }

    @Test
    fun streamUrlFormat() {
        assertEquals(
            "http://jf:8096/Videos/i42/stream?Static=true&api_key=tok",
            JellyfinApi.streamUrl("http://jf:8096/", "i42", "tok"),
        )
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
    fun browseUrlSkipsBlankParentId() {
        assertEquals(
            "http://jf:8096/Users/u1/Items?Recursive=false&Fields=Path",
            JellyfinApi.browseUrl("http://jf:8096", "u1", ""),
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
}
