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
            "https://jf/proxy/Items/item%2F1?UserId=user%2F1",
            JellyfinApi.itemDetailsUrl("https://jf/proxy/", "user/1", "item/1"),
        )
    }
}
