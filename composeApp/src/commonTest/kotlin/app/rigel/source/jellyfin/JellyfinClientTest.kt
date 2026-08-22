package app.rigel.source.jellyfin

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException

class JellyfinClientTest {

    private val base = "http://jf:8096"

    @Test
    fun authenticateParsesTokenAndUser() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<Pair<String, String>>()
        val json = """{"AccessToken":"tok123","User":{"Id":"u456","Name":"alice"}}"""
        val engine = MockEngine { request ->
            requests += request.url.toString() to ((request.body as? TextContent)?.text ?: "")
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        val auth = JellyfinClient(HttpClient(engine)).authenticate(base, "alice", "pw", "dev-1")
        assertNotNull(auth)
        assertEquals("tok123", auth.token)
        assertEquals("u456", auth.userId)
        assertEquals("$base/Users/AuthenticateByName", requests[0].first)
        assertTrue(requests[0].second.contains("\"Username\":\"alice\""))
        assertTrue(requests[0].second.contains("\"Pw\":\"pw\""))
    }

    @Test
    fun authenticateNullWithoutToken() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("""{"User":{"Id":"u"}}""", HttpStatusCode.OK) }
        assertNull(JellyfinClient(HttpClient(engine)).authenticate(base, "a", "p", "d"))
    }

    @Test
    fun authenticateNullOnNetworkError() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw RuntimeException("unreachable") }
        assertNull(JellyfinClient(HttpClient(engine)).authenticate(base, "a", "p", "d"))
    }

    @Test
    fun browseParsesItemsAndFolderFlag() = kotlinx.coroutines.test.runTest {
        val json = """[
            {"Id":"i1","Name":"Movies","Type":"Folder"},
            {"Id":"i2","Name":"File.mp4","Type":"Video"}
        ]"""
        val engine = MockEngine { respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }
        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", "root")
        assertEquals(2, items.size)
        assertEquals(JellyfinItem("i1", "Movies", isFolder = true), items[0])
        assertEquals(JellyfinItem("i2", "File.mp4", isFolder = false), items[1])
    }

    @Test
    fun browseParsesWrappedItemsWithNestedDataAndEscapedName() = kotlinx.coroutines.test.runTest {
        val json = """{"Items":[
            {"Id":"folder-1","Name":"Movies","Type":"CollectionFolder","IsFolder":true,
             "UserData":{"Played":false},
             "MediaSources":[{"Id":"source-1","Name":"nested source","Type":"Default"}]},
            {"Id":"movie-1","Name":"A \"quoted\" movie","Type":"Movie","IsFolder":false}
        ],"TotalRecordCount":2}"""
        val engine = MockEngine {
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
        assertEquals(
            listOf(
                JellyfinItem("folder-1", "Movies", isFolder = true),
                JellyfinItem("movie-1", "A \"quoted\" movie", isFolder = false),
            ),
            items,
        )
    }

    @Test
    fun browsePreservesNavigableSeriesSeasons() = kotlinx.coroutines.test.runTest {
        val json = """{"Items":[
            {"Id":"series-1","Name":"The Expanse","Type":"Series","IsFolder":true},
            {"Id":"season-1","Name":"Season 1","Type":"Season","IsFolder":true},
            {"Id":"episode-1","Name":"Pilot","Type":"Episode","IsFolder":false}
        ]}"""
        val engine = MockEngine {
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }

        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", "series-1")

        assertEquals(
            listOf(
                JellyfinItem("series-1", "The Expanse", isFolder = true),
                JellyfinItem("season-1", "Season 1", isFolder = true),
                JellyfinItem("episode-1", "Pilot", isFolder = false),
            ),
            items,
        )
    }

    @Test
    fun searchCallsJellyfinItemsEndpoint() = kotlinx.coroutines.test.runTest {
        val requested = mutableListOf<String>()
        val engine = MockEngine { request ->
            requested += request.url.toString()
            respond(
                """{"Items":[{"Id":"m1","Name":"Star Wars","Type":"Movie"},{"Id":"s1","Name":"The Expanse","Type":"Series"}]}""",
                HttpStatusCode.OK,
                headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val items = JellyfinClient(HttpClient(engine)).search(base, "tok", "u1", "star wars")
        assertEquals(
            listOf(
                JellyfinItem("m1", "Star Wars", isFolder = false),
                JellyfinItem("s1", "The Expanse", isFolder = true),
            ),
            items,
        )
        assertEquals(
            "$base/Users/u1/Items?Recursive=true&SearchTerm=star%20wars&IncludeItemTypes=Movie,Series,Episode,Video&Fields=Path",
            requested.single(),
        )
    }

    @Test
    fun browsePropagatesNetworkError() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw RuntimeException("unreachable") }
        assertFailsWith<RuntimeException> {
            JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
        }
    }

    @Test
    fun browsePropagatesUnauthorizedResponse() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine {
            respond("", HttpStatusCode.Unauthorized, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        assertFailsWith<JellyfinRequestException> {
            JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
        }
    }

    @Test
    fun browsePropagatesMalformedResponse() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine {
            respond("{not-json", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        assertFailsWith<IllegalStateException> {
            JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
        }
    }

    @Test
    fun browsePropagatesCancellation() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw CancellationException("cancelled") }
        assertFailsWith<CancellationException> {
            JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
        }
    }

    @Test
    fun sessionsParseDeviceAndClient() = kotlinx.coroutines.test.runTest {
        val json = """[
            {"Id":"s1","DeviceName":"iPhone","Client":"Jellyfin Mobile"},
            {"Id":"s2","DeviceName":"Living Room","Client":"Jellyfin for Roku"}
        ]"""
        val engine = MockEngine { respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }
        val sessions = JellyfinClient(HttpClient(engine)).sessions(base, "tok")
        assertEquals(2, sessions.size)
        assertEquals(JellyfinSession("s1", "iPhone", "Jellyfin Mobile"), sessions[0])
        assertEquals(JellyfinSession("s2", "Living Room", "Jellyfin for Roku"), sessions[1])
    }

    @Test
    fun playToSessionPostsPlayCommand() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<Pair<String, String>>()
        val engine = MockEngine { request ->
            if (request.method == HttpMethod.Post) {
                posted += request.url.toString() to ((request.body as? TextContent)?.text ?: "")
            }
            respond("", HttpStatusCode.OK)
        }
        val ok = JellyfinClient(HttpClient(engine)).playToSession(base, "tok", "s1", listOf("a", "b"))
        assertTrue(ok)
        assertEquals("$base/Sessions/s1/Playing", posted[0].first)
        assertTrue(posted[0].second.contains("\"ItemIds\":[\"a\",\"b\"]"))
    }

    @Test
    fun playToSessionFalseOnNon2xx() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.InternalServerError) }
        assertFalse(JellyfinClient(HttpClient(engine)).playToSession(base, "tok", "s1", listOf("a")))
    }
}
