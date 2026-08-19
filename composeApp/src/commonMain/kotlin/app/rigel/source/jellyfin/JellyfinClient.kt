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
            .append("/Users/").append(userId)
            .append("/Items?Recursive=false&Fields=Path")
        if (!parentId.isNullOrBlank()) sb.append("&ParentId=").append(parentId)
        return sb.toString()
    }

    /** Direct file stream URL — feeds the normal probe→route pipeline. */
    fun streamUrl(base: String, itemId: String, token: String): String =
        base.trimEnd('/') + "/Videos/$itemId/stream?Static=true&api_key=$token"

    fun playCommand(itemIds: List<String>, command: String = "PlayNow"): String =
        """{"ItemIds":[${itemIds.joinToString(",") { "\"$it\"" }}],"PlayCommand":"$command","StartPositionTicks":0}"""

    fun jsonEscape(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"")
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

    suspend fun browse(base: String, token: String, userId: String, parentId: String?): List<JellyfinItem> {
        val url = JellyfinApi.browseUrl(base, userId, parentId)
        val resp = runCatching {
            http.get(url) { header("X-Emby-Token", token) }.bodyAsText()
        }.getOrNull() ?: return emptyList()
        val out = mutableListOf<JellyfinItem>()
        for (m in Regex("""\{[^{}]*?"Id":"([^"]+)"[^{}]*?"Name":"([^"]+)"[^{}]*?"Type":"([^"]+)"[^{}]*?}""").findAll(resp)) {
            val id = m.groupValues[1]
            val name = m.groupValues[2]
            val type = m.groupValues[3]
            out += JellyfinItem(id, name, type == "Folder")
        }
        return out
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
}
