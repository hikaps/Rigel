package app.rigel.source.jellyfin

import app.rigel.bridge.SubtitleTrack
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
    fun authenticateRejectsNonSuccessResponsesEvenWithTokenLikeBody() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine {
            respond("""{"AccessToken":"secret","User":{"Id":"u1"}}""", HttpStatusCode.Unauthorized)
        }

        assertNull(JellyfinClient(HttpClient(engine)).authenticate(base, "a", "p", "d"))
    }

    @Test
    fun authenticateRequiresNestedUserId() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine {
            respond("""{"AccessToken":"tok","Id":"unrelated"}""", HttpStatusCode.OK)
        }

        assertNull(JellyfinClient(HttpClient(engine)).authenticate(base, "a", "p", "d"))
    }

    @Test
    fun authenticatePropagatesCancellation() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw CancellationException("cancelled") }

        assertFailsWith<CancellationException> {
            JellyfinClient(HttpClient(engine)).authenticate(base, "a", "p", "d")
        }
    }

    @Test
    fun browseParsesItemsAndFolderFlag() = kotlinx.coroutines.test.runTest {
        val json = """[
            {"Id":"i1","Name":"Movies","Type":"Folder"},
            {"Id":"i2","Name":"File.mp4","Type":"Video"}
        ]"""
        val engine = MockEngine { respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }
        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", "root").items
        assertEquals(2, items.size)
        assertEquals(JellyfinItem("i1", "Movies", isFolder = true, type = "Folder"), items[0])
        assertEquals(JellyfinItem("i2", "File.mp4", isFolder = false, type = "Video"), items[1])
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
        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null).items
        assertEquals(
            listOf(
                JellyfinItem("folder-1", "Movies", isFolder = true, type = "CollectionFolder"),
                JellyfinItem("movie-1", "A \"quoted\" movie", isFolder = false, type = "Movie"),
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

        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", "series-1").items

        assertEquals(
            listOf(
                JellyfinItem("series-1", "The Expanse", isFolder = true, type = "Series"),
                JellyfinItem("season-1", "Season 1", isFolder = true, type = "Season"),
                JellyfinItem("episode-1", "Pilot", isFolder = false, type = "Episode"),
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
        val items = JellyfinClient(HttpClient(engine)).search(base, "tok", "u1", "star wars").items
        assertEquals(
            listOf(
                JellyfinItem("m1", "Star Wars", isFolder = false, type = "Movie"),
                JellyfinItem("s1", "The Expanse", isFolder = true, type = "Series"),
            ),
            items,
        )
        assertEquals(
            "$base/Items?UserId=u1&Recursive=true&SearchTerm=star%20wars&IncludeItemTypes=Movie,Series,Episode,Video&StartIndex=0&Limit=50&EnableTotalRecordCount=true&EnableImages=false",
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
        val error = assertFailsWith<JellyfinRequestException> {
            JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
        }
        assertEquals(401, error.statusCode)
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
    fun browseHonorsExplicitIsFolderFalse() = kotlinx.coroutines.test.runTest {
        val json = """{"Items":[
            {"Id":"season-1","Name":"Season 1","Type":"Season","IsFolder":false}
        ]}"""
        val engine = MockEngine {
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        val items = JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null).items
        assertEquals(listOf(JellyfinItem("season-1", "Season 1", isFolder = false, type = "Season")), items)
    }

    @Test
    fun browsePropagatesMalformedNumber() = kotlinx.coroutines.test.runTest {
        for (payload in listOf(
            """{"Items":[{"Id":-,"Name":"x","Type":"Movie"}]}""",
            """{"Items":[{"Id":1+2,"Name":"x","Type":"Movie"}]}""",
            """{"Items":[{"Id":1e,"Name":"x","Type":"Movie"}]}""",
            """{"Items":[{"Id":1.,"Name":"x","Type":"Movie"}]}""",
            """{"Items":[{"Id":01,"Name":"x","Type":"Movie"}]}""",
        )) {
            val engine = MockEngine {
                respond(payload, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            }
            assertFailsWith<IllegalStateException>("payload should fail: $payload") {
                JellyfinClient(HttpClient(engine)).browse(base, "tok", "u1", null)
            }
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
    fun sessionsFilterControllableClientsAndIgnorePropertyOrder() = kotlinx.coroutines.test.runTest {
        val requested = mutableListOf<String>()
        val json = """[
            {"Id":"s1","Client":"Jellyfin Mobile","DeviceName":"iPhone","SupportsMediaControl":true},
            {"Id":"s2","Client":"Jellyfin Web","DeviceName":"Browser","SupportsMediaControl":false}
        ]"""
        val engine = MockEngine { request ->
            requested += request.url.toString()
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        val sessions = JellyfinClient(HttpClient(engine)).sessions(base, "tok", "user-1")

        assertEquals("$base/Sessions?controllableByUserId=user-1", requested.single())
        assertEquals(1, sessions.size)
        assertEquals(
            JellyfinSession("s1", "iPhone", "Jellyfin Mobile", base, supportsMediaControl = true),
            sessions.single(),
        )
    }

    @Test
    fun playToSessionUsesJellyfinQueryParameters() = kotlinx.coroutines.test.runTest {
        val requested = mutableListOf<io.ktor.http.Url>()
        val engine = MockEngine { request ->
            if (request.method == HttpMethod.Post) requested += request.url
            respond("", HttpStatusCode.OK)
        }
        val ok = JellyfinClient(HttpClient(engine)).playToSession(base, "tok", "s1", listOf("a", "b"))

        assertTrue(ok)
        val url = requested.single()
        assertEquals("/Sessions/s1/Playing", url.encodedPath)
        assertEquals("PlayNow", url.parameters["playCommand"])
        assertEquals("a,b", url.parameters["itemIds"])
        assertEquals("0", url.parameters["startPositionTicks"])
    }
    @Test
    fun playToSessionSendsTheChosenMediaSource() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<io.ktor.http.Url>()
        val engine = MockEngine { request ->
            posted += request.url
            respond("", HttpStatusCode.NoContent)
        }

        assertTrue(
            JellyfinClient(HttpClient(engine)).playToSession(
                base, "tok", "s1", listOf("item1"), mediaSourceId = "version/2",
            ),
        )
        assertEquals("version/2", posted.single().parameters["mediaSourceId"])
    }

    @Test
    fun playToSessionFalseOnNon2xx() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.InternalServerError) }
        assertFalse(JellyfinClient(HttpClient(engine)).playToSession(base, "tok", "s1", listOf("a")))
    }
    @Test
    fun playToSessionPropagatesCancellation() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw CancellationException("cancelled") }
        assertFailsWith<CancellationException> {
            JellyfinClient(HttpClient(engine)).playToSession(base, "tok", "s1", listOf("item1"))
        }
    }

    @Test
    fun stopSessionPostsStopCommand() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            posted += request.url.toString()
            respond("", HttpStatusCode.NoContent)
        }
        val ok = JellyfinClient(HttpClient(engine)).stopSession(base, "tok", "s1")
        assertTrue(ok)
        assertEquals("$base/Sessions/s1/Playing/Stop", posted.single())
    }

    @Test
    fun stopSessionFalseOnNon2xx() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.InternalServerError) }
        assertFalse(JellyfinClient(HttpClient(engine)).stopSession(base, "tok", "s1"))
    }
    @Test
    fun stopSessionPropagatesCancellation() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw CancellationException("cancelled") }
        assertFailsWith<CancellationException> {
            JellyfinClient(HttpClient(engine)).stopSession(base, "tok", "s1")
        }
    }

    @Test
    fun itemMediaSourcesKeepMetadataAndSubtitlesPairedWithEachVersion() = kotlinx.coroutines.test.runTest {
        val json = """
            {
              "MediaStreams": [
                {"Index": 4, "Type": "Subtitle", "Language": "deu", "DisplayTitle": "Wrong item subtitle", "IsExternal": true}
              ],
              "MediaSources": [
                {
                  "MediaStreams": [
                    {"Index": 0, "Type": "Video", "Codec": "h264", "Width": 1920, "Height": 1080},
                    {"Index": 1, "Type": "Audio", "Codec": "aac", "Channels": 2},
                    {"Index": 4, "Type": "Subtitle", "Language": "eng", "DisplayTitle": "English", "IsExternal": true}
                  ],
                  "Id": "ms-first", "Name": "1080p", "Container": "mkv", "Size": 1000
                },
                {
                  "Id": "ms-second", "Name": "2160p", "Container": "mp4", "Size": 2000,
                  "MediaStreams": [
                    {"Index": 0, "Type": "Video", "Codec": "hevc", "Width": 3840, "Height": 2160},
                    {"Index": 1, "Type": "Audio", "Codec": "dts", "Channels": 6},
                    {"Index": 4, "Type": "Subtitle", "Language": "fra", "DisplayTitle": "French", "IsExternal": true}
                  ]
                },
                {"Id": "ms-second", "Name": "duplicate", "Container": "avi"},
                {"Id": "", "Name": "missing identity", "Container": "mkv"}
              ]
            }
        """.trimIndent()
        val engine = MockEngine { request ->
            assertEquals("$base/Items/item1?UserId=u1", request.url.toString())
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }

        val sources = JellyfinClient(HttpClient(engine)).itemMediaSources(base, "tok", "u1", "item1")

        assertEquals(
            listOf(
                JellyfinMediaSource(
                    id = "ms-first", name = "1080p", container = "mkv", width = 1920, height = 1080,
                    videoCodec = "h264", audioCodec = "aac", audioChannels = 2, sizeBytes = 1000,
                    subtitleTracks = listOf(SubtitleTrack("$base/Videos/item1/ms-first/Subtitles/4/Stream.vtt?api_key=tok", "eng", "English")),
                ),
                JellyfinMediaSource(
                    id = "ms-second", name = "2160p", container = "mp4", width = 3840, height = 2160,
                    videoCodec = "hevc", audioCodec = "dts", audioChannels = 6, sizeBytes = 2000,
                    subtitleTracks = listOf(SubtitleTrack("$base/Videos/item1/ms-second/Subtitles/4/Stream.vtt?api_key=tok", "fra", "French")),
                ),
            ),
            sources,
        )
    }

    @Test
    fun oneMediaSourceUsesTopLevelSubtitleFallback() = kotlinx.coroutines.test.runTest {
        val json = """{"MediaStreams":[{"Index":2,"Type":"Subtitle","Language":"eng","IsExternal":true}],"MediaSources":[{"Id":"ms1","Container":"mkv"}]}"""
        val engine = MockEngine { respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }

        val sources = JellyfinClient(HttpClient(engine)).itemMediaSources(base, "tok", "u1", "item1")

        assertEquals(1, sources.size)
        assertEquals(
            listOf(SubtitleTrack("$base/Videos/item1/ms1/Subtitles/2/Stream.vtt?api_key=tok", "eng", "eng")),
            sources.single().subtitleTracks,
        )
    }

    @Test
    fun multipleMediaSourcesNeverBorrowTopLevelSubtitles() = kotlinx.coroutines.test.runTest {
        val json = """{"MediaStreams":[{"Index":2,"Type":"Subtitle","Language":"eng","IsExternal":true}],"MediaSources":[{"Id":"ms1"},{"Id":"ms2"}]}"""
        val engine = MockEngine { respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }

        val sources = JellyfinClient(HttpClient(engine)).itemMediaSources(base, "tok", "u1", "item1")

        assertEquals(listOf("ms1", "ms2"), sources.map(JellyfinMediaSource::id))
        assertTrue(sources.all { it.subtitleTracks.isEmpty() })
    }
    @Test
    fun browseReturnsPageMetadataAndCountsRawEntries() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<io.ktor.http.Url>()
        val json = """{"Items":[{"Id":"a","Name":"Movie","Type":"Movie","ProductionYear":2024},{"Id":"","Name":"skip","Type":"Video"},null],"TotalRecordCount":153}"""
        val engine = MockEngine { request ->
            requests += request.url
            respond(json, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }

        val page = JellyfinClient(HttpClient(engine)).browse(
            base, "tok", "u1", "root", startIndex = 50, limit = 50, order = JellyfinBrowseOrder.EPISODE,
        )

        assertEquals(listOf(JellyfinItem("a", "Movie", false, "Movie", 2024, null, null, null)), page.items)
        assertEquals(153, page.totalRecordCount)
        assertEquals(50, page.startIndex)
        assertEquals(3, page.receivedCount)
        assertEquals("/Items", requests.single().encodedPath)
        assertEquals("u1", requests.single().parameters["UserId"])
        assertEquals("root", requests.single().parameters["ParentId"])
        assertEquals("50", requests.single().parameters["StartIndex"])
        assertEquals("50", requests.single().parameters["Limit"])
        assertEquals("ParentIndexNumber,IndexNumber,SortName", requests.single().parameters["SortBy"])
    }

    @Test
    fun searchUsesSelectedTypeFilterAndTreatsMissingTotalAsUnknown() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<io.ktor.http.Url>()
        val engine = MockEngine { request ->
            requests += request.url
            respond("""{"Items":[{"Id":"m1","Name":"Amélie","Type":"Movie"}]}""", HttpStatusCode.OK)
        }

        val page = JellyfinClient(HttpClient(engine)).search(
            base, "tok", "u1", " Amélie & friends ", JellyfinSearchFilter.MOVIES, 0, 50,
        )

        assertEquals(listOf("m1"), page.items.map(JellyfinItem::id))
        assertEquals(null, page.totalRecordCount)
        assertEquals("Amélie & friends", requests.single().parameters["SearchTerm"])
        assertEquals("Movie", requests.single().parameters["IncludeItemTypes"])
        assertEquals("0", requests.single().parameters["StartIndex"])
        assertEquals("50", requests.single().parameters["Limit"])
    }

    @Test
    fun browseRejectsInvalidPagingAndBlankSearchDoesNotRequest() = kotlinx.coroutines.test.runTest {
        var requestCount = 0
        val engine = MockEngine {
            requestCount++
            respond("[]", HttpStatusCode.OK)
        }
        val client = JellyfinClient(HttpClient(engine))
        assertFailsWith<IllegalArgumentException> {
            client.browse(base, "tok", "u1", null, startIndex = -1, limit = 50, order = JellyfinBrowseOrder.NAME)
        }
        assertFailsWith<IllegalArgumentException> {
            client.search(base, "tok", "u1", "x", JellyfinSearchFilter.ALL, 0, 0)
        }
        assertEquals(0, client.search(base, "tok", "u1", " \n ", JellyfinSearchFilter.ALL, 0, 50).receivedCount)
        assertEquals(0, requestCount)
    }
}
