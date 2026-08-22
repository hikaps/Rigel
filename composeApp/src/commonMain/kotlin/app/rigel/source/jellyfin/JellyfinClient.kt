package app.rigel.source.jellyfin

import co.touchlab.kermit.Logger
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
 * Small dependency-free JSON walker. It exposes scalar fields for every object
 * and recursively visits nested objects, which is sufficient for Jellyfin's
 * item envelopes on all supported targets.
 */
private class JsonObjectReader(
    private val source: String,
    private val onObject: (Map<String, String>) -> Unit,
) {
    private var index = 0

    fun parseItems() {
        skipWhitespace()
        when {
            takeIf('[') -> {
                index--
                parseItemArray()
            }
            takeIf('{') -> {
                index--
                parseItemsEnvelope()
            }
            else -> error("Expected Jellyfin item array or envelope")
        }
        skipWhitespace()
        if (index != source.length) error("Trailing JSON content")
    }

    private fun parseItemsEnvelope() {
        expect('{')
        skipWhitespace()
        if (takeIf('}')) return
        while (true) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            expect(':')
            skipWhitespace()
            if (key == "Items" && index < source.length && source[index] == '[') {
                parseItemArray()
            } else {
                parseValue(emitObjects = false)
            }
            skipWhitespace()
            when {
                takeIf('}') -> return
                takeIf(',') -> Unit
                else -> error("Expected object separator at $index")
            }
        }
    }

    private fun parseItemArray() {
        expect('[')
        skipWhitespace()
        if (takeIf(']')) return
        while (true) {
            skipWhitespace()
            if (index < source.length && source[index] == '{') {
                onObject(parseObject(emitObject = false))
            } else {
                parseValue(emitObjects = false)
            }
            skipWhitespace()
            when {
                takeIf(']') -> return
                takeIf(',') -> Unit
                else -> error("Expected array separator at $index")
            }
        }
    }

    private fun parseValue(emitObjects: Boolean): String? {
        skipWhitespace()
        if (index >= source.length) error("Missing JSON value")
        return when (source[index]) {
            '"' -> parseString()
            '{' -> {
                parseObject(emitObjects)
                null
            }
            '[' -> {
                parseArray(emitObjects)
                null
            }
            't' -> {
                consumeLiteral("true")
                "true"
            }
            'f' -> {
                consumeLiteral("false")
                "false"
            }
            'n' -> {
                consumeLiteral("null")
                null
            }
            '-', in '0'..'9' -> parseNumber()
            else -> error("Invalid JSON value at $index")
        }
    }

    private fun parseObject(emitObject: Boolean): Map<String, String> {
        expect('{')
        val fields = mutableMapOf<String, String>()
        skipWhitespace()
        if (takeIf('}')) {
            if (emitObject) onObject(fields)
            return fields
        }
        while (true) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            expect(':')
            parseValue(emitObjects = false)?.let { fields[key] = it }
            skipWhitespace()
            when {
                takeIf('}') -> {
                    if (emitObject) onObject(fields)
                    return fields
                }
                takeIf(',') -> Unit
                else -> error("Expected object separator at $index")
            }
        }
    }

    private fun parseArray(emitObjects: Boolean) {
        expect('[')
        skipWhitespace()
        if (takeIf(']')) return
        while (true) {
            parseValue(emitObjects)
            skipWhitespace()
            when {
                takeIf(']') -> return
                takeIf(',') -> Unit
                else -> error("Expected array separator at $index")
            }
        }
    }

    private fun parseString(): String {
        expect('"')
        val out = StringBuilder()
        while (index < source.length) {
            when (val c = source[index++]) {
                '"' -> return out.toString()
                '\\' -> {
                    if (index >= source.length) error("Unterminated JSON escape")
                    when (val escaped = source[index++]) {
                        '"', '\\', '/' -> out.append(escaped)
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            if (index + 4 > source.length) error("Incomplete unicode escape")
                            out.append(source.substring(index, index + 4).toInt(16).toChar())
                            index += 4
                        }
                        else -> error("Invalid JSON escape: $escaped")
                    }
                }
                else -> {
                    if (c < ' ') error("Unescaped control character")
                    out.append(c)
                }
            }
        }
        error("Unterminated JSON string")
    }

    private fun parseNumber(): String {
        val start = index
        if (index < source.length && source[index] == '-') index++
        // Integer part: single 0 or non-zero lead.
        if (index < source.length && source[index] == '0') {
            index++
        } else {
            val digitsStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == digitsStart) error("Invalid JSON number at $start")
        }
        if (index < source.length && source[index] !in ",}] \n\r\t" &&
            source[index] != '.' && source[index] != 'e' && source[index] != 'E'
        ) {
            error("Invalid JSON number at $start")
        }
        if (index < source.length && source[index] == '.') {
            index++
            val fracStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == fracStart) error("Invalid JSON number at $start")
        }
        if (index < source.length && (source[index] == 'e' || source[index] == 'E')) {
            index++
            if (index < source.length && (source[index] == '+' || source[index] == '-')) index++
            val expStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == expStart) error("Invalid JSON number at $start")
        }
        if (index < source.length && source[index] !in ",}] \n\r\t") {
            error("Invalid JSON number at $start")
        }
        return source.substring(start, index)
    }

    private fun consumeLiteral(literal: String) {
        if (!source.startsWith(literal, index)) error("Invalid JSON literal at $index")
        index += literal.length
    }

    private fun skipWhitespace() {
        while (index < source.length && source[index] in " \n\r\t") index++
    }

    private fun expect(c: Char) {
        if (index >= source.length || source[index] != c) error("Expected '$c' at $index")
        index++
    }

    private fun takeIf(c: Char): Boolean {
        if (index < source.length && source[index] == c) {
            index++
            return true
        }
        return false
    }
}
