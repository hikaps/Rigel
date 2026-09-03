package app.rigel.source.jellyfin

import co.touchlab.kermit.Logger
import app.rigel.bridge.SubtitleTrack

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException

data class JellyfinItem(
    val id: String,
    val name: String,
    val isFolder: Boolean,
)

data class JellyfinSession(
    val id: String,
    val deviceName: String,
    val client: String,
)

data class JellyfinAuth(
    val token: String,
    val userId: String,
)

private data class JellyfinSubtitleCandidate(
    val index: Int,
    val language: String?,
    val title: String?,
)

/**
 * Pure request builders for the Jellyfin REST API. Unit-tested.
 * Jellyfin plays arbitrary-URL pushes? No — session Play commands accept
 * library ItemIds only (platform limit, surfaced in UI).
 */
object JellyfinApi {
    fun authBody(username: String, password: String): String =
        """{"Username":"${jsonEscape(username)}","Pw":"${jsonEscape(password)}"}"""

    fun embyAuthHeader(deviceId: String, client: String = "Rigel", device: String = "Rigel iOS", version: String = "1.0"): String =
        "MediaBrowser Client=\"$client\", Device=\"$device\", DeviceId=\"$deviceId\", Version=\"$version\""

    fun browseUrl(base: String, userId: String, parentId: String?): String {
        val sb = StringBuilder(base.trimEnd('/'))
            .append("/Users/").append(encodeUrlComponent(userId))
            .append("/Items?Recursive=false&Fields=Path")
        if (!parentId.isNullOrBlank()) sb.append("&ParentId=").append(encodeUrlComponent(parentId))
        return sb.toString()
    }

    fun searchUrl(base: String, userId: String, term: String): String =
        base.trimEnd('/') +
            "/Users/${encodeUrlComponent(userId)}/Items" +
            "?Recursive=true" +
            "&SearchTerm=${encodeUrlComponent(term)}" +
            "&IncludeItemTypes=Movie,Series,Episode,Video" +
            "&Fields=Path"

    /** Direct file stream URL — feeds the normal probe→route pipeline. */
    fun streamUrl(base: String, itemId: String, token: String): String =
        base.trimEnd('/') + "/Videos/$itemId/stream?Static=true&api_key=$token"

    fun itemDetailsUrl(base: String, userId: String, itemId: String): String =
        base.trimEnd('/') +
            "/Users/${encodeUrlComponent(userId)}/Items/${encodeUrlComponent(itemId)}" +
            "?Fields=MediaStreams,MediaSources"

    fun subtitleStreamUrl(
        base: String,
        itemId: String,
        mediaSourceId: String,
        index: Int,
        token: String,
    ): String =
        base.trimEnd('/') +
            "/Videos/${encodeUrlComponent(itemId)}/${encodeUrlComponent(mediaSourceId)}" +
            "/Subtitles/$index/Stream.vtt?api_key=${encodeUrlComponent(token)}"

    fun playCommand(itemIds: List<String>, command: String = "PlayNow"): String =
        """{"ItemIds":[${itemIds.joinToString(",") { "\"$it\"" }}],"PlayCommand":"$command","StartPositionTicks":0}"""

    fun jsonEscape(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"")

    private fun encodeUrlComponent(value: String): String {
        val hex = "0123456789ABCDEF"
        return buildString {
            for (byte in value.encodeToByteArray()) {
                val unsigned = byte.toInt() and 0xff
                val c = unsigned.toChar()
                if (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '-' || c == '_' || c == '.' || c == '~') {
                    append(c)
                } else {
                    append('%')
                    append(hex[unsigned ushr 4])
                    append(hex[unsigned and 0x0f])
                }
            }
        }
    }
}

/** Jellyfin client operations (ktor). */
class JellyfinClient(private val http: HttpClient) {
    private val tag = "JellyfinClient"

    suspend fun authenticate(base: String, username: String, password: String, deviceId: String): JellyfinAuth? {
        val body = JellyfinApi.authBody(username, password)
        val resp = runCatching {
            http.post(base.trimEnd('/') + "/Users/AuthenticateByName") {
                contentType(ContentType.Application.Json)
                header("X-Emby-Authorization", JellyfinApi.embyAuthHeader(deviceId))
                setBody(body)
            }.bodyAsText()
        }.getOrNull() ?: return null
        val token = Regex(""""AccessToken":"([^"]+)"""").find(resp)?.groupValues?.get(1)
        val userId = Regex(""""User":\{[^}]*?"Id":"([^"]+)"""").find(resp)?.groupValues?.get(1)
            ?: Regex(""""Id":"([^"]+)"""").find(resp)?.groupValues?.get(1)
        if (token == null || userId == null) {
            Logger.w(tag) { "auth failed: $resp" }
            return null
        }
        return JellyfinAuth(token, userId)
    }
    @Throws(Exception::class)
    suspend fun browse(base: String, token: String, userId: String, parentId: String?): List<JellyfinItem> =
        fetchItems(JellyfinApi.browseUrl(base, userId, parentId), token)

    /** Search Jellyfin itself rather than filtering the currently loaded folder. */
    @Throws(Exception::class)
    suspend fun search(base: String, token: String, userId: String, term: String): List<JellyfinItem> {
        if (term.isBlank()) return emptyList()
        return fetchItems(JellyfinApi.searchUrl(base, userId, term.trim()), token)
    }

    @Throws(Exception::class)
    suspend fun itemSubtitleTracks(
        base: String,
        token: String,
        userId: String,
        itemId: String,
    ): List<SubtitleTrack> {
        val response = http.get(JellyfinApi.itemDetailsUrl(base, userId, itemId)) {
            header("X-Emby-Token", token)
        }
        if (!response.status.isSuccess()) {
            throw JellyfinRequestException("Jellyfin request failed (${response.status.value})")
        }
        val sourceIds = mutableMapOf<Int, String>()
        val nestedCandidates = mutableMapOf<Int, MutableList<JellyfinSubtitleCandidate>>()
        val topLevelCandidates = mutableListOf<JellyfinSubtitleCandidate>()
        fun candidate(fields: Map<String, String>): JellyfinSubtitleCandidate? {
            if (!fields["Type"].equals("Subtitle", ignoreCase = true)) return null
            if (!fields["IsExternal"].equals("true", ignoreCase = true)) return null
            val index = fields["Index"]?.toIntOrNull() ?: return null
            return JellyfinSubtitleCandidate(
                index = index,
                language = fields["Language"]?.takeIf { it.isNotBlank() },
                title = fields["DisplayTitle"]?.takeIf { it.isNotBlank() },
            )
        }
        JsonObjectReader(
            source = response.bodyAsText(),
            onObjectAtPath = { path, fields ->
                when {
                    path.size == 2 && path[0] == "MediaSources" -> {
                        val index = path[1].toIntOrNull()
                        val id = fields["Id"]
                        if (index != null && id != null && id.isNotBlank()) {
                            sourceIds[index] = id
                        }
                    }
                    path.size >= 4 &&
                        path[0] == "MediaSources" &&
                        path[2] == "MediaStreams" -> {
                        val sourceIndex = path[1].toIntOrNull() ?: return@JsonObjectReader
                        candidate(fields)?.let {
                            nestedCandidates.getOrPut(sourceIndex) { mutableListOf() } += it
                        }
                    }
                    path.size == 2 && path[0] == "MediaStreams" -> {
                        candidate(fields)?.let { topLevelCandidates += it }
                    }
                }
            },
        ).parseObjectsWithPaths()
        val firstSource = sourceIds.entries.firstOrNull() ?: return emptyList()
        val candidates = (nestedCandidates[firstSource.key].orEmpty().ifEmpty { topLevelCandidates })
            .distinctBy { it.index }
        return candidates.map { candidate ->
            SubtitleTrack(
                url = JellyfinApi.subtitleStreamUrl(
                    base = base,
                    itemId = itemId,
                    mediaSourceId = firstSource.value,
                    index = candidate.index,
                    token = token,
                ),
                language = candidate.language,
                title = candidate.title ?: candidate.language ?: "Subtitle ${candidate.index}",
            )
        }
    }

    suspend fun sessions(base: String, token: String): List<JellyfinSession> {
        val resp = runCatching {
            http.get(base.trimEnd('/') + "/Sessions") { header("X-Emby-Token", token) }.bodyAsText()
        }.getOrNull() ?: return emptyList()
        val out = mutableListOf<JellyfinSession>()
        for (m in Regex("""\{[^{}]*?"Id":"([^"]+)"[^{}]*?"DeviceName":"([^"]+)"[^{}]*?"Client":"([^"]+)"[^{}]*?}""").findAll(resp)) {
            out += JellyfinSession(m.groupValues[1], m.groupValues[2], m.groupValues[3])
        }
        return out
    }

    /** Cast a library item to a logged-in Jellyfin client session. */
    suspend fun playToSession(base: String, token: String, sessionId: String, itemIds: List<String>): Boolean {
        val resp = runCatching {
            http.post(base.trimEnd('/') + "/Sessions/$sessionId/Playing") {
                header("X-Emby-Token", token)
                contentType(ContentType.Application.Json)
                setBody(JellyfinApi.playCommand(itemIds))
            }.status.value
        }.getOrNull()
        return resp != null && resp in 200..299
    }

    private suspend fun fetchItems(url: String, token: String): List<JellyfinItem> {
        try {
            val response = http.get(url) { header("X-Emby-Token", token) }
            if (!response.status.isSuccess()) {
                throw JellyfinRequestException("Jellyfin request failed (${response.status.value})")
            }
            return parseItems(response.bodyAsText())
        } catch (cancelled: CancellationException) {
            throw cancelled
        }
    }

    /**
     * Jellyfin returns both bare arrays and an object containing an Items array.
     * Parse JSON structure instead of relying on property order or flat objects;
     * real responses contain nested UserData and MediaSources objects.
     */
    private fun parseItems(response: String): List<JellyfinItem> {
        val out = mutableListOf<JellyfinItem>()
        JsonObjectReader(response) { fields ->
            val id = fields["Id"] ?: return@JsonObjectReader
            val name = fields["Name"] ?: return@JsonObjectReader
            val type = fields["Type"] ?: return@JsonObjectReader
            val isFolder = fields["IsFolder"]?.equals("true", ignoreCase = true)
                ?: (type in folderItemTypes)
            out += JellyfinItem(id, name, isFolder)
        }.parseItems()
        return out
    }

    private companion object {
        /**
         * IsFolder is authoritative when Jellyfin sends it. These type fallbacks
         * keep navigation working for minimal server responses and older servers.
         */
        val folderItemTypes = setOf(
            "AggregateFolder",
            "BoxSet",
            "CollectionFolder",
            "Folder",
            "Genre",
            "MusicAlbum",
            "MusicArtist",
            "Playlist",
            "Series",
            "Season",
            "Studio",
            "UserView",
        )
    }
}

class JellyfinRequestException(message: String) : Exception(message)

/**
 * Swift-facing classifier for Kotlin throwables that Kotlin/Native carries
 * inside NSError.userInfo["KotlinException"]. The exported KotlinThrowable
 * does not conform to Swift Error, so Swift must ask Kotlin directly.
 */
object JellyfinInterop {
    fun isCancellation(throwable: Throwable): Boolean =
        throwable is CancellationException

    /** Swift test support: a cancellation throwable with the exported type. */
    fun makeCancellationThrowable(): Throwable = CancellationException("cancelled")
}
