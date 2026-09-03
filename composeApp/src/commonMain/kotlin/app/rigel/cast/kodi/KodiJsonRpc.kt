package app.rigel.cast.kodi

import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.userAgent

/**
 * Pure JSON-RPC builders for Kodi (HTTP port 8080, JSON-RPC 2.0).
 * Kodi settings: Settings → Services → Control → "Allow remote control via HTTP".
 * Unit-tested with exact request strings.
 */
object KodiJsonRpc {
    fun request(method: String, params: String? = null): String =
        if (params == null) {
            """{"jsonrpc":"2.0","id":1,"method":"$method"}"""
        } else {
            """{"jsonrpc":"2.0","id":1,"method":"$method","params":$params}"""
        }

    /** Launch playback of a file/URL on the default player (playerid 1). */
    fun playerOpenFile(url: String): String =
        request("Player.Open", """{"item":{"file":"${jsonEscape(url)}"}}""")

    fun playerPlayPause(): String = request("Player.PlayPause", """{"playerid":1}""")
    fun playerStop(): String = request("Player.Stop", """{"playerid":1}""")
    fun playerSeekPercentage(percent: Double): String =
        request("Player.Seek", """{"playerid":1,"value":{"percentage":$percent}}""")

    fun playerGetProperties(): String =
        request(
            "Player.GetProperties",
            """{"playerid":1,"properties":["percentage","time","totaltime"]}""",
        )

    fun jsonEscape(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"")

    /** Parse {"hours":H,"minutes":M,"seconds":S,"milliseconds":MS} → ms. Pure — testable. */
    internal fun parseTimeObject(json: String, key: String): Long? {
        val m = Regex("\"$key\"\\s*:\\s*\\{([^}]*)\\}").find(json) ?: return null
        val body = m.groupValues[1]
        fun grab(name: String): Long =
            Regex("\"$name\"\\s*:\\s*(\\d+)").find(body)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
        val h = grab("hours")
        val min = grab("minutes")
        val s = grab("seconds")
        val ms = grab("milliseconds")
        return ((h * 3600 + min * 60 + s) * 1000) + ms
    }
}

/** Kodi control over JSON-RPC. */
class KodiRenderer(private val client: HttpClient) {
    private val tag = "KodiRenderer"

    suspend fun isKodi(endpoint: String): Boolean {
        val resp = runCatching {
            client.get(endpoint + "/jsonrpc?v=1") { userAgent("Rigel/1.0") }.status.value
        }.getOrNull()
        return resp != null && resp in 200..299
    }

    suspend fun rpc(endpoint: String, body: String): String? {
        return runCatching {
            client.post(endpoint + "/jsonrpc") {
                contentType(ContentType.Application.Json)
                userAgent("Rigel/1.0")
                setBody(body)
            }.bodyAsText()
        }.onFailure { Logger.w(tag, it) { "rpc failed: $endpoint $body" } }.getOrNull()
    }

    suspend fun launch(endpoint: String, url: String): Boolean {
        val resp = rpc(endpoint, KodiJsonRpc.playerOpenFile(url)) ?: return false
        return !resp.contains("\"error\"")
    }

    suspend fun playPause(endpoint: String) = rpc(endpoint, KodiJsonRpc.playerPlayPause())
    suspend fun stop(endpoint: String) = rpc(endpoint, KodiJsonRpc.playerStop())
    suspend fun seek(endpoint: String, percent: Double) = rpc(endpoint, KodiJsonRpc.playerSeekPercentage(percent))

    /** Returns (positionMs, durationMs) or null when no player/position. */
    suspend fun position(endpoint: String): Pair<Long, Long>? {
        val resp = rpc(endpoint, KodiJsonRpc.playerGetProperties()) ?: return null
        val time = KodiJsonRpc.parseTimeObject(resp, "time") ?: return null
        val total = KodiJsonRpc.parseTimeObject(resp, "totaltime") ?: return null
        return time to total
    }
}
