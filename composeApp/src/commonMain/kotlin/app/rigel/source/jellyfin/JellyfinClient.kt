package app.rigel.source.jellyfin

import app.rigel.bridge.SubtitleTrack
import app.rigel.output.OutputMediaProfiles

import io.ktor.client.HttpClient
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.http.takeFrom
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

data class JellyfinPlayback(
    val url: String,
    val mediaSourceId: String,
    val subtitleTracks: List<SubtitleTrack>,
    val playSessionId: String?,
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

private fun subtitleCandidate(fields: Map<String, String>): JellyfinSubtitleCandidate? {
    if (!fields["Type"].equals("Subtitle", ignoreCase = true)) return null
    if (!fields["IsExternal"].equals("true", ignoreCase = true)) return null
    val index = fields["Index"]?.toIntOrNull()?.takeIf { it >= 0 } ?: return null
    return JellyfinSubtitleCandidate(
        index = index,
        language = fields["Language"]?.takeIf { it.isNotBlank() },
        title = fields["DisplayTitle"]?.takeIf { it.isNotBlank() },
    )
}

private fun subtitlesForSource(
    base: String,
    itemId: String,
    mediaSourceId: String,
    token: String,
    candidates: List<JellyfinSubtitleCandidate>,
): List<SubtitleTrack> = candidates.distinctBy { it.index }.map { candidate ->
    SubtitleTrack(
        url = JellyfinApi.subtitleStreamUrl(base, itemId, mediaSourceId, candidate.index, token),
        language = candidate.language,
        title = candidate.title ?: candidate.language ?: ("Subtitle " + candidate.index),
    )
}

private data class JellyfinPlaybackSource(
    val id: String,
    val fields: Map<String, String>,
    val mediaStreams: List<Map<String, String>>,
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

    fun resumeUrl(base: String, userId: String, limit: Int): String {
        require(limit > 0) { "limit must be positive" }
        return buildString {
            append(base.trimEnd('/')).append("/UserItems/Resume?UserId=").append(encodeUrlComponent(userId))
            append("&Limit=").append(limit)
            append("&MediaTypes=Video&EnableImages=false")
        }
    }

    fun nextUpUrl(base: String, userId: String, limit: Int): String {
        require(limit > 0) { "limit must be positive" }
        return buildString {
            append(base.trimEnd('/')).append("/Shows/NextUp?UserId=").append(encodeUrlComponent(userId))
            append("&Limit=").append(limit)
            append("&EnableImages=false")
        }
    }

    /** Static source URL for the negotiated SupportsDirectPlay fallback when no server URL is supplied. */
    fun streamUrl(base: String, itemId: String, token: String, mediaSourceId: String): String =
        base.trimEnd('/') +
            "/Videos/" + encodeUrlComponent(itemId) + "/stream" +
            "?Static=true&MediaSourceId=" + encodeUrlComponent(mediaSourceId) +
            "&api_key=" + encodeUrlComponent(token)

    internal fun isTokenizedJellyfinStream(url: String): Boolean {
        val path = url.substringBefore('?')
        if (!path.contains("/Videos/", ignoreCase = true) || !path.endsWith("/stream", ignoreCase = true)) return false
        val parsed = runCatching { Url(url) }.getOrNull() ?: return false
        return parsed.parameters.names().any { it.equals("api_key", ignoreCase = true) }
    }
    fun itemDetailsUrl(base: String, userId: String, itemId: String): String =
        base.trimEnd('/') + "/Items/" + encodeUrlComponent(itemId) +
            "?UserId=" + encodeUrlComponent(userId) + "&Fields=MediaStreams,MediaSources"

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

    fun playbackInfoUrl(base: String, itemId: String): String =
        base.trimEnd('/') + "/Items/" + encodeUrlComponent(itemId) + "/PlaybackInfo"

    fun stopPlaybackUrl(base: String, playSessionId: String): String =
        base.trimEnd('/') + "/Videos/ActiveEncodings?DeviceId=rigel-ios&PlaySessionId=" + encodeUrlComponent(playSessionId)

    fun playbackInfoBody(userId: String, mediaSourceId: String?): String = buildString {
        append("{\"UserId\":\"").append(jsonEscape(userId)).append('"')
        mediaSourceId?.let { append(",\"MediaSourceId\":\"").append(jsonEscape(it)).append('"') }
        append(",\"IsPlayback\":true,\"AutoOpenLiveStream\":true")
        append(",\"EnableDirectPlay\":true,\"EnableDirectStream\":true,\"EnableTranscoding\":true")
        append(",\"AllowVideoStreamCopy\":true,\"AllowAudioStreamCopy\":true,\"DeviceProfile\":")
        append(localDeviceProfileJson).append('}')
    }

    private val localDeviceProfileJson: String by lazy { buildLocalDeviceProfileJson() }
    private fun buildLocalDeviceProfileJson(): String {
        val profile = OutputMediaProfiles.local
        return buildString {
            append("{\"Name\":\"Rigel iOS\",\"DirectPlayProfiles\":[{\"Container\":\"")
            append(profile.directContainers.sorted().joinToString(","))
            append("\",\"Type\":\"Video\",\"VideoCodec\":\"")
            append(profile.directVideoCodecs.sorted().joinToString(","))
            append("\",\"AudioCodec\":\"")
            append(profile.directAudioCodecs.sorted().joinToString(","))
            append("\"}],\"TranscodingProfiles\":[{\"Container\":\"ts\",\"Type\":\"Video\",\"VideoCodec\":\"")
            append(profile.hlsVideoCodecs.sorted().joinToString(","))
            append("\",\"AudioCodec\":\"")
            append(profile.hlsAudioCodecs.sorted().joinToString(","))
            append("\",\"Protocol\":\"hls\",\"Context\":\"Streaming\",\"EnableSubtitlesInManifest\":")
            append(profile.supportsHlsWebVtt)
            append("}],\"SubtitleProfiles\":")
            if (profile.supportsHlsWebVtt) {
                append("[{\"Format\":\"vtt\",\"Method\":\"Hls\"}]")
            } else {
                append("[]")
            }
            append('}')
        }
    }

    internal fun resolvePlaybackUrl(base: String, negotiatedUrl: String, token: String): String? {
        if (negotiatedUrl.isBlank() || negotiatedUrl.any { it.isWhitespace() || it.code < 0x20 }) return null
        if (!hasExplicitScheme(negotiatedUrl) && !negotiatedUrl.startsWith("//") && negotiatedUrl.substringBefore('?').isBlank()) return null
        if (hasUserInfo(base)) return null
        val serverUrl = runCatching { Url(base.trimEnd('/')) }.getOrNull() ?: return null
        val serverOrigin = playbackOrigin(serverUrl) ?: return null
        if (serverUrl.parameters.names().isNotEmpty() || serverUrl.fragment.isNotEmpty()) return null
        val mountPath = serverUrl.encodedPath.trimEnd('/')
        if (!isSafePlaybackPath(serverUrl.encodedPath.ifEmpty { "/" }, allowRoot = true)) return null

        val absoluteReference = hasExplicitScheme(negotiatedUrl) || negotiatedUrl.startsWith("//")
        val resolved = when {
            hasExplicitScheme(negotiatedUrl) -> negotiatedUrl
            negotiatedUrl.startsWith("//") -> "${serverOrigin.scheme}:$negotiatedUrl"
            negotiatedUrl.startsWith('/') -> {
                val rootPath = rawUrlPath(negotiatedUrl)
                val alreadyMounted = mountPath.isEmpty() || rootPath == mountPath || rootPath.startsWith("$mountPath/")
                val mountedPath = if (alreadyMounted) rootPath else mountPath + rootPath
                originPrefix(serverOrigin) + mountedPath + negotiatedUrl.substring(rootPath.length)
            }
            else -> base.trimEnd('/') + "/" + negotiatedUrl
        }
        if ('#' in resolved || hasUserInfo(resolved)) return null
        if (!isSafePlaybackPath(rawUrlPath(resolved), allowRoot = false)) return null
        val target = runCatching { Url(resolved) }.getOrNull() ?: return null
        if (playbackOrigin(target) != serverOrigin) return null
        if (!isSafePlaybackPath(target.encodedPath, allowRoot = false)) return null
        if (absoluteReference && mountPath.isNotEmpty() && target.encodedPath != mountPath && !target.encodedPath.startsWith("$mountPath/")) return null

        val builder = URLBuilder().apply { takeFrom(resolved) }
        builder.parameters.names()
            .filter { it.equals("api_key", ignoreCase = true) || it.equals("apikey", ignoreCase = true) }
            .forEach(builder.parameters::remove)
        builder.parameters.append("api_key", token)
        return builder.buildString()
    }

    private data class PlaybackOrigin(val scheme: String, val host: String, val port: Int)

    private fun playbackOrigin(url: Url): PlaybackOrigin? {
        val scheme = url.protocol.name.lowercase()
        if (scheme != "http" && scheme != "https") return null
        val host = url.host.takeIf { it.isNotBlank() }?.lowercase() ?: return null
        val port = url.port.takeIf { it > 0 } ?: if (scheme == "https") 443 else 80
        return PlaybackOrigin(scheme, host, port)
    }

    private fun originPrefix(origin: PlaybackOrigin): String {
        val host = origin.host.let { if (it.contains(':') && !it.startsWith('[')) "[$it]" else it }
        val defaultPort = if (origin.scheme == "https") 443 else 80
        return origin.scheme + "://" + host + if (origin.port == defaultPort) "" else ":${origin.port}"
    }

    private fun hasUserInfo(value: String): Boolean {
        if (!value.contains("://")) return false
        return value.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#').contains('@')
    }

    private fun hasExplicitScheme(value: String): Boolean {
        val colon = value.indexOf(':')
        if (colon <= 0) return false
        val scheme = value.substring(0, colon)
        return scheme.first().isLetter() && scheme.all { it.isLetterOrDigit() || it == '+' || it == '.' || it == '-' }
    }

    private fun rawUrlPath(value: String): String {
        val authorityStart = value.indexOf("://")
        if (authorityStart < 0) return value.substringBefore('?').substringBefore('#')
        val pathStart = value.indexOf('/', authorityStart + 3)
        return if (pathStart < 0) "/" else value.substring(pathStart).substringBefore('?').substringBefore('#')
    }

    private fun isSafePlaybackPath(path: String, allowRoot: Boolean): Boolean {
        if (!path.startsWith('/') || path.startsWith("//") || '\\' in path) return false
        if (path == "/") return allowRoot
        if (path.any { it.isWhitespace() || it.code < 0x20 || it.code == 0x7f }) return false
        var index = 0
        while (index < path.length) {
            if (path[index] == '%') {
                if (index + 2 >= path.length || path[index + 1].digitToIntOrNull(16) == null || path[index + 2].digitToIntOrNull(16) == null) {
                    return false
                }
                index += 3
            } else {
                index++
            }
        }
        for (segment in path.substring(1).split('/')) {
            val lower = segment.lowercase()
            if ("%2f" in lower || "%5c" in lower) return false
            val decodedDots = lower.replace("%2e", ".")
            if (decodedDots == "." || decodedDots == "..") return false
        }
        return true
    }

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

    fun stopSessionUrl(base: String, sessionId: String): String =
        base.trimEnd('/') + "/Sessions/" + encodeUrlComponent(sessionId) + "/Playing/Stop"

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

    @Throws(Exception::class)
    suspend fun resume(
        base: String,
        token: String,
        userId: String,
        limit: Int = 20,
    ): JellyfinItemPage = fetchItems(JellyfinApi.resumeUrl(base, userId, limit), token, 0)

    @Throws(Exception::class)
    suspend fun nextUp(
        base: String,
        token: String,
        userId: String,
        limit: Int = 20,
    ): JellyfinItemPage = fetchItems(JellyfinApi.nextUpUrl(base, userId, limit), token, 0)

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
                subtitleTracks = subtitlesForSource(base, itemId, id, token, subtitleCandidates),
            )
        }
    }

    @Throws(Exception::class)
    suspend fun playback(
        base: String,
        token: String,
        userId: String,
        itemId: String,
        mediaSourceId: String?,
    ): JellyfinPlayback {
        val response = http.post(JellyfinApi.playbackInfoUrl(base, itemId)) {
            header("X-Emby-Token", token)
            contentType(ContentType.Application.Json)
            setBody(JellyfinApi.playbackInfoBody(userId, mediaSourceId))
        }
        if (!response.status.isSuccess()) throw JellyfinRequestException(response.status.value)

        val sourceFieldsByIndex = mutableMapOf<Int, Map<String, String>>()
        val streamsBySourceIndex = mutableMapOf<Int, MutableList<Map<String, String>>>()
        val topLevelSubtitles = mutableListOf<JellyfinSubtitleCandidate>()
        var mediaSourceCount = 0
        var playSessionId: String? = null
        var errorCode: String? = null
        JsonObjectReader(
            source = response.bodyAsText(),
            onObjectAtPath = { path, fields ->
                if (path.isEmpty()) {
                    playSessionId = fields["PlaySessionId"]?.takeIf { it.isNotBlank() }
                    errorCode = fields["ErrorCode"]?.takeIf { it.isNotBlank() }
                    return@JsonObjectReader
                }
                when {
                    path.size == 2 && path[0] == "MediaSources" -> {
                        path[1].toIntOrNull()?.let { sourceFieldsByIndex[it] = fields }
                    }
                    path.size >= 4 && path[0] == "MediaSources" && path[2] == "MediaStreams" -> {
                        val sourceIndex = path[1].toIntOrNull() ?: return@JsonObjectReader
                        streamsBySourceIndex.getOrPut(sourceIndex) { mutableListOf() } += fields
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

        if (!errorCode.isNullOrBlank()) throw JellyfinPlaybackException(errorCode)
        val seenIds = mutableSetOf<String>()
        val sources = sourceFieldsByIndex.keys.sorted().mapNotNull { sourceIndex ->
            val fields = sourceFieldsByIndex.getValue(sourceIndex)
            val id = fields["Id"]?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            if (!seenIds.add(id)) return@mapNotNull null
            JellyfinPlaybackSource(id, fields, streamsBySourceIndex[sourceIndex].orEmpty())
        }
        var resolvedPlaybackUrl: String? = null
        val selected = if (mediaSourceId == null) {
            sources.firstOrNull { source ->
                val candidateUrl = playbackUrlFor(base, token, itemId, source)
                if (candidateUrl == null) false else {
                    resolvedPlaybackUrl = candidateUrl
                    true
                }
            }
        } else {
            sources.firstOrNull { it.id == mediaSourceId }
        } ?: throw JellyfinPlaybackException()
        val url = resolvedPlaybackUrl ?: playbackUrlFor(base, token, itemId, selected) ?: throw JellyfinPlaybackException()
        val nestedSubtitles = selected.mediaStreams.mapNotNull(::subtitleCandidate).distinctBy { it.index }
        val subtitleCandidates = if (nestedSubtitles.isEmpty() && mediaSourceCount == 1) {
            topLevelSubtitles
        } else {
            nestedSubtitles
        }
        return JellyfinPlayback(
            url = url,
            mediaSourceId = selected.id,
            subtitleTracks = subtitlesForSource(base, itemId, selected.id, token, subtitleCandidates),
            playSessionId = playSessionId,
        )
    }

    private fun playbackUrlFor(
        base: String,
        token: String,
        itemId: String,
        source: JellyfinPlaybackSource,
    ): String? {
        val supportsDirectPlay = source.fields["SupportsDirectPlay"].equals("true", ignoreCase = true)
        val supportsDirectStream = source.fields["SupportsDirectStream"].equals("true", ignoreCase = true)
        val supportsTranscoding = source.fields["SupportsTranscoding"].equals("true", ignoreCase = true)
        val directUrl = source.fields["DirectStreamUrl"]?.takeIf { it.isNotBlank() }
        val transcodingUrl = source.fields["TranscodingUrl"]?.takeIf { it.isNotBlank() }

        if (supportsDirectPlay || supportsDirectStream) {
            directUrl?.let { JellyfinApi.resolvePlaybackUrl(base, it, token) }?.let { return it }
        }
        if (supportsTranscoding) {
            transcodingUrl?.let { JellyfinApi.resolvePlaybackUrl(base, it, token) }?.let { return it }
        }
        if (supportsDirectPlay && directUrl == null && transcodingUrl == null) {
            return JellyfinApi.resolvePlaybackUrl(base, JellyfinApi.streamUrl(base, itemId, token, source.id), token)
        }
        return null
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
        if (status !in 200..299) throw JellyfinRequestException(status)
        return true
    }
    @Throws(Exception::class)
    suspend fun stopPlayback(base: String, token: String, playSessionId: String): Boolean {
        if (playSessionId.isBlank()) return false
        val status = try {
            http.delete(JellyfinApi.stopPlaybackUrl(base, playSessionId)) {
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
            http.post(JellyfinApi.stopSessionUrl(base, sessionId)) {
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

class JellyfinPlaybackException(val errorCode: String? = null) :
    Exception("Jellyfin playback negotiation failed")

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
