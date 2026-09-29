package app.rigel.source.jellyfin

import app.rigel.bridge.SubtitleTrack

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.Url
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.CancellationException

data class JellyfinItem(
    val id: String,
    val name: String,
    val isFolder: Boolean,
    val type: String,
    val productionYear: Int? = null,
    val seriesName: String? = null,
    val parentIndexNumber: Int? = null,
    val indexNumber: Int? = null,
)

enum class JellyfinSearchFilter(val includeItemTypes: String) {
    ALL("Movie,Series,Episode,Video"),
    MOVIES("Movie"),
    SERIES("Series"),
    EPISODES("Episode"),
}

enum class JellyfinBrowseOrder { NAME, EPISODE }

data class JellyfinItemPage(
    val items: List<JellyfinItem>,
    val totalRecordCount: Int?,
    val startIndex: Int,
    val receivedCount: Int,
)
data class JellyfinMediaSource(
    val id: String,
    val name: String?,
    val container: String?,
    val width: Int?,
    val height: Int?,
    val videoCodec: String?,
    val audioCodec: String?,
    val audioChannels: Int?,
    val sizeBytes: Long?,
    val subtitleTracks: List<SubtitleTrack>,
)

data class JellyfinSession(
    val id: String,
    val deviceName: String,
    val client: String,
    val serverBase: String = "",
    val supportsMediaControl: Boolean? = null,
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
    fun normalizeServerBase(value: String): String {
        val trimmed = value.trim().trimEnd('/')
        val url = runCatching { Url(trimmed) }.getOrNull() ?: return trimmed
        val host = url.host.lowercase().let { host ->
            if (host.contains(':') && !host.startsWith('[')) "[$host]" else host
        }
        val authority = buildString {
            append(host)
            if (url.port != url.protocol.defaultPort) append(':').append(url.port)
        }
        return url.protocol.name.lowercase() + "://" + authority + url.encodedPath.trimEnd('/')
    }

    fun authBody(username: String, password: String): String =
        """{"Username":"${jsonEscape(username)}","Pw":"${jsonEscape(password)}"}"""
    fun embyAuthHeader(deviceId: String, client: String = "Rigel", device: String = "Rigel iOS", version: String = "1.0"): String =
        "MediaBrowser Client=\"$client\", Device=\"$device\", DeviceId=\"$deviceId\", Version=\"$version\""

    fun browseUrl(
        base: String,
        userId: String,
        parentId: String?,
        startIndex: Int,
        limit: Int,
        order: JellyfinBrowseOrder,
    ): String {
        require(startIndex >= 0) { "startIndex must not be negative" }
        require(limit > 0) { "limit must be positive" }
        return buildString {
            append(base.trimEnd('/')).append("/Items?UserId=").append(encodeUrlComponent(userId))
            append("&Recursive=false")
            if (!parentId.isNullOrBlank()) append("&ParentId=").append(encodeUrlComponent(parentId))
            append("&StartIndex=").append(startIndex)
            append("&Limit=").append(limit)
            append("&EnableTotalRecordCount=true&EnableImages=false")
            when (order) {
                JellyfinBrowseOrder.NAME -> append("&SortBy=SortName&SortOrder=Ascending")
                JellyfinBrowseOrder.EPISODE -> append("&SortBy=ParentIndexNumber%2CIndexNumber%2CSortName&SortOrder=Ascending")
            }
        }
    }

    fun searchUrl(
        base: String,
        userId: String,
        term: String,
        filter: JellyfinSearchFilter,
        startIndex: Int,
        limit: Int,
    ): String {
        require(startIndex >= 0) { "startIndex must not be negative" }
        require(limit > 0) { "limit must be positive" }
        return buildString {
            append(base.trimEnd('/')).append("/Items?UserId=").append(encodeUrlComponent(userId))
            append("&Recursive=true&SearchTerm=").append(encodeUrlComponent(term))
            append("&IncludeItemTypes=").append(filter.includeItemTypes)
            append("&StartIndex=").append(startIndex)
            append("&Limit=").append(limit)
            append("&EnableTotalRecordCount=true&EnableImages=false")
        }
    }

    /** Direct selected-version URL — feeds the normal probe→route pipeline. */
    fun streamUrl(base: String, itemId: String, token: String, mediaSourceId: String): String =
        base.trimEnd('/') +
            "/Videos/" + encodeUrlComponent(itemId) + "/stream" +
            "?Static=true&MediaSourceId=" + encodeUrlComponent(mediaSourceId) +
            "&api_key=" + encodeUrlComponent(token)

    fun itemDetailsUrl(base: String, userId: String, itemId: String): String =
        base.trimEnd('/') + "/Items/" + encodeUrlComponent(itemId) +
            "?UserId=" + encodeUrlComponent(userId)

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

    fun playUrl(
        base: String,
        sessionId: String,
        itemIds: List<String>,
        command: String = "PlayNow",
        startPositionTicks: Long = 0,
        mediaSourceId: String? = null,
    ): String = buildString {
        append(base.trimEnd('/')).append("/Sessions/").append(encodeUrlComponent(sessionId)).append("/Playing")
        append("?playCommand=").append(encodeUrlComponent(command))
        append("&itemIds=").append(itemIds.joinToString(",") { encodeUrlComponent(it) })
        append("&startPositionTicks=").append(startPositionTicks)
        mediaSourceId?.let { append("&mediaSourceId=").append(encodeUrlComponent(it)) }
    }

    fun sessionsUrl(base: String, userId: String): String =
        base.trimEnd('/') + "/Sessions?controllableByUserId=${encodeUrlComponent(userId)}"

    fun startPositionTicks(positionMs: Long): Long =
        positionMs.coerceAtLeast(0).coerceAtMost(Long.MAX_VALUE / 10_000L) * 10_000L

    fun jsonEscape(s: String): String = buildString(s.length) {
        val hex = "0123456789ABCDEF"
        for (char in s) {
            when (char) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\b' -> append("\\b")
                '\t' -> append("\\t")
                '\n' -> append("\\n")
                '\u000C' -> append("\\f")
                '\r' -> append("\\r")
                else -> {
                    if (char.code < 0x20) {
                        val code = char.code
                        append("\\u00")
                        append(hex[code ushr 4])
                        append(hex[code and 0x0F])
                    } else {
                        append(char)
                    }
                }
            }
        }
    }

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
    @Throws(Exception::class)
    suspend fun authenticate(base: String, username: String, password: String, deviceId: String): JellyfinAuth? {
        val body = JellyfinApi.authBody(username, password)
        val response = try {
            http.post(base.trimEnd('/') + "/Users/AuthenticateByName") {
                contentType(ContentType.Application.Json)
                header("X-Emby-Authorization", JellyfinApi.embyAuthHeader(deviceId))
                setBody(body)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return null
        }
        if (!response.status.isSuccess()) return null

        val responseBody = try {
            response.bodyAsText()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return null
        }
        var token: String? = null
        var userId: String? = null
        try {
            JsonObjectReader(
                source = responseBody,
                onObjectAtPath = { path, fields ->
                    when (path) {
                        emptyList<String>() -> token = fields["AccessToken"]?.takeIf { it.isNotBlank() }
                        listOf("User") -> userId = fields["Id"]?.takeIf { it.isNotBlank() }
                    }
                },
            ).parseObjectsWithPaths()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return null
        }
        val accessToken = token ?: return null
        val authenticatedUserId = userId ?: return null
        return JellyfinAuth(accessToken, authenticatedUserId)
    }
    @Throws(Exception::class)
    suspend fun browse(
        base: String,
        token: String,
        userId: String,
        parentId: String?,
        startIndex: Int = 0,
        limit: Int = 50,
        order: JellyfinBrowseOrder = JellyfinBrowseOrder.NAME,
    ): JellyfinItemPage = fetchItems(
        JellyfinApi.browseUrl(base, userId, parentId, startIndex, limit, order), token, startIndex,
    )

    /** Search Jellyfin itself rather than filtering the currently loaded folder. */
    @Throws(Exception::class)
    suspend fun search(
        base: String,
        token: String,
        userId: String,
        term: String,
        filter: JellyfinSearchFilter = JellyfinSearchFilter.ALL,
        startIndex: Int = 0,
        limit: Int = 50,
    ): JellyfinItemPage {
        require(startIndex >= 0) { "startIndex must not be negative" }
        require(limit > 0) { "limit must be positive" }
        if (term.isBlank()) return JellyfinItemPage(emptyList(), null, startIndex, 0)
        return fetchItems(JellyfinApi.searchUrl(base, userId, term.trim(), filter, startIndex, limit), token, startIndex)
    }

    @Throws(Exception::class)
    suspend fun itemMediaSources(
        base: String,
        token: String,
        userId: String,
        itemId: String,
    ): List<JellyfinMediaSource> {
        val response = http.get(JellyfinApi.itemDetailsUrl(base, userId, itemId)) {
            header("X-Emby-Token", token)
        }
        if (!response.status.isSuccess()) {
            throw JellyfinRequestException(response.status.value)
        }

        val sourcesByIndex = mutableMapOf<Int, Map<String, String>>()
        val streamsBySourceIndex = mutableMapOf<Int, MutableList<Map<String, String>>>()
        val subtitlesBySourceIndex = mutableMapOf<Int, MutableList<JellyfinSubtitleCandidate>>()
        val topLevelSubtitles = mutableListOf<JellyfinSubtitleCandidate>()
        var mediaSourceCount = 0

        fun subtitleCandidate(fields: Map<String, String>): JellyfinSubtitleCandidate? {
            if (!fields["Type"].equals("Subtitle", ignoreCase = true)) return null
            if (!fields["IsExternal"].equals("true", ignoreCase = true)) return null
            val index = fields["Index"]?.toIntOrNull()?.takeIf { it >= 0 } ?: return null
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
                        path[1].toIntOrNull()?.let { sourcesByIndex[it] = fields }
                    }
                    path.size >= 4 && path[0] == "MediaSources" && path[2] == "MediaStreams" -> {
                        val sourceIndex = path[1].toIntOrNull() ?: return@JsonObjectReader
                        streamsBySourceIndex.getOrPut(sourceIndex) { mutableListOf() } += fields
                        subtitleCandidate(fields)?.let {
                            subtitlesBySourceIndex.getOrPut(sourceIndex) { mutableListOf() } += it
                        }
                    }
                    path.size == 2 && path[0] == "MediaStreams" -> {
                        subtitleCandidate(fields)?.let { topLevelSubtitles += it }
                    }
                }
            },
            onArrayAtPath = { path, count ->
                if (path == listOf("MediaSources")) mediaSourceCount = count
            },
        ).parseObjectsWithPaths()

        val seenIds = mutableSetOf<String>()
        return sourcesByIndex.keys.sorted().mapNotNull { sourceIndex ->
            val fields = sourcesByIndex.getValue(sourceIndex)
            val id = fields["Id"]?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            if (!seenIds.add(id)) return@mapNotNull null
            val streams = streamsBySourceIndex[sourceIndex].orEmpty()
            val video = streams.firstOrNull { it["Type"].equals("Video", ignoreCase = true) }
            val audio = streams.firstOrNull { it["Type"].equals("Audio", ignoreCase = true) }
            val nestedSubtitles = subtitlesBySourceIndex[sourceIndex].orEmpty().distinctBy { it.index }
            val subtitleCandidates = if (nestedSubtitles.isEmpty() && mediaSourceCount == 1) {
                topLevelSubtitles.distinctBy { it.index }
            } else {
                nestedSubtitles
            }
            JellyfinMediaSource(
                id = id,
                name = fields["Name"]?.takeIf { it.isNotBlank() },
                container = fields["Container"]?.takeIf { it.isNotBlank() },
                width = video?.get("Width")?.toIntOrNull()?.takeIf { it > 0 },
                height = video?.get("Height")?.toIntOrNull()?.takeIf { it > 0 },
                videoCodec = video?.get("Codec")?.takeIf { it.isNotBlank() },
                audioCodec = audio?.get("Codec")?.takeIf { it.isNotBlank() },
                audioChannels = audio?.get("Channels")?.toIntOrNull()?.takeIf { it > 0 },
                sizeBytes = fields["Size"]?.toLongOrNull()?.takeIf { it > 0 },
                subtitleTracks = subtitleCandidates.map { candidate ->
                    SubtitleTrack(
                        url = JellyfinApi.subtitleStreamUrl(base, itemId, id, candidate.index, token),
                        language = candidate.language,
                        title = candidate.title ?: candidate.language ?: ("Subtitle " + candidate.index),
                    )
                },
            )
        }
    }

    suspend fun sessions(base: String, token: String, userId: String): List<JellyfinSession> {
        val normalizedBase = JellyfinApi.normalizeServerBase(base)
        val resp = try {
            http.get(JellyfinApi.sessionsUrl(normalizedBase, userId)) {
                header("X-Emby-Token", token)
            }.bodyAsText()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            return emptyList()
        }
        val out = mutableListOf<JellyfinSession>()
        JsonObjectReader(
            source = resp,
            onObjectAtPath = { path, fields ->
                if (path.size != 1) return@JsonObjectReader
                val id = fields["Id"] ?: return@JsonObjectReader
                val deviceName = fields["DeviceName"] ?: return@JsonObjectReader
                val client = fields["Client"] ?: return@JsonObjectReader
                val supportsMediaControl = fields["SupportsMediaControl"]
                    ?.let { it.equals("true", ignoreCase = true) }
                    ?: fields["SupportsRemoteControl"]
                        ?.let { it.equals("true", ignoreCase = true) }
                if (supportsMediaControl == false) return@JsonObjectReader
                out += JellyfinSession(id, deviceName, client, normalizedBase, supportsMediaControl)
            },
        ).parseObjectsWithPaths()
        return out
    }
    /** Cast a library item and its selected version to a logged-in Jellyfin client. */
    @Throws(Exception::class)
    suspend fun playToSession(
        base: String,
        token: String,
        sessionId: String,
        itemIds: List<String>,
        startPositionTicks: Long = 0,
        mediaSourceId: String? = null,
    ): Boolean {
        val status = try {
            http.post(
                JellyfinApi.playUrl(
                    base,
                    sessionId,
                    itemIds,
                    startPositionTicks = startPositionTicks,
                    mediaSourceId = mediaSourceId,
                ),
            ) {
                header("X-Emby-Token", token)
            }.status.value
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            return false
        }
        return status in 200..299
    }

    /** Remote stop command for a client session (Playing/Stopped is the client-side report endpoint; it does not stop playback). */
    suspend fun stopSession(base: String, token: String, sessionId: String): Boolean {
        val resp = try {
            http.post(base.trimEnd('/') + "/Sessions/$sessionId/Playing/Stop") {
                header("X-Emby-Token", token)
            }.status.value
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            null
        }
        return resp != null && resp in 200..299
    }

    private suspend fun fetchItems(url: String, token: String, startIndex: Int): JellyfinItemPage {
        try {
            val response = http.get(url) { header("X-Emby-Token", token) }
            if (!response.status.isSuccess()) {
                throw JellyfinRequestException(response.status.value)
            }
            val items = mutableListOf<JellyfinItem>()
            val metadata = JsonObjectReader(response.bodyAsText()) { fields ->
                val id = fields["Id"]?.takeIf { it.isNotBlank() } ?: return@JsonObjectReader
                val name = fields["Name"]?.takeIf { it.isNotBlank() } ?: return@JsonObjectReader
                val type = fields["Type"]?.takeIf { it.isNotBlank() } ?: return@JsonObjectReader
                val isFolder = fields["IsFolder"]?.equals("true", ignoreCase = true)
                    ?: (type in folderItemTypes)
                items += JellyfinItem(
                    id = id,
                    name = name,
                    isFolder = isFolder,
                    type = type,
                    productionYear = fields["ProductionYear"]?.toIntOrNull(),
                    seriesName = fields["SeriesName"]?.takeIf { it.isNotBlank() },
                    parentIndexNumber = fields["ParentIndexNumber"]?.toIntOrNull(),
                    indexNumber = fields["IndexNumber"]?.toIntOrNull(),
                )
            }.parseItems()
            return JellyfinItemPage(
                items = items,
                totalRecordCount = metadata.fields["TotalRecordCount"]?.toIntOrNull()?.takeIf { it >= 0 },
                startIndex = startIndex,
                receivedCount = metadata.receivedCount,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        }
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

class JellyfinRequestException(val statusCode: Int) :
    Exception("Jellyfin request failed ($statusCode)")

/** Swift-facing classifiers for Kotlin exceptions carried by Kotlin/Native. */
object JellyfinInterop {
    fun isCancellation(throwable: Throwable): Boolean =
        throwable is CancellationException

    fun httpStatusCode(throwable: Throwable): Int? =
        (throwable as? JellyfinRequestException)?.statusCode

    /** Test seam mirroring the exception Kotlin throws for HTTP failures. */
    fun makeRequestException(statusCode: Int): Throwable = JellyfinRequestException(statusCode)

    /** Swift test support: a cancellation throwable with the exported type. */
    fun makeCancellationThrowable(): Throwable = CancellationException("cancelled")
}
