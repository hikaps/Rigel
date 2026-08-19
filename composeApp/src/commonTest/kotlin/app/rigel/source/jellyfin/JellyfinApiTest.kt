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
    fun streamUrlFormat() {
        assertEquals(
            "http://jf:8096/Videos/i42/stream?Static=true&api_key=tok",
            JellyfinApi.streamUrl("http://jf:8096/", "i42", "tok"),
        )
    }

    @Test
    fun playCommandBodies() {
        assertEquals(
            """{"ItemIds":["a","b"],"PlayCommand":"PlayNow","StartPositionTicks":0}""",
            JellyfinApi.playCommand(listOf("a", "b")),
        )
        assertTrue(JellyfinApi.playCommand(listOf("x")).contains("\"PlayCommand\":\"PlayNow\""))
    }
}
