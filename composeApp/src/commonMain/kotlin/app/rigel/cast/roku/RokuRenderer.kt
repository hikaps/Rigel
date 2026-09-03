package app.rigel.cast.roku

import app.rigel.cast.RokuDevice
import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.userAgent

/** Roku device operations over ECP. No seek/position — platform limitation, shown in UI. */
class RokuRenderer(private val client: HttpClient) {
    private val tag = "RokuRenderer"

    suspend fun fetchDeviceInfo(usn: String, location: String): RokuDevice? {
        val base = location.trimEnd('/') + "/"
        val xml = runCatching { client.get(base + "query/device-info").bodyAsText() }.getOrNull()
            ?: return null
        val info = RokuEcp.parseDeviceInfo(xml) ?: return null
        if (!info.hasPlayOnRoku) return null
        return RokuDevice(usn, base, info.modelName)
    }

    suspend fun launchPlayOnRoku(device: RokuDevice, mediaUrl: String): Boolean {
        val channelId = resolvePlayChannelId(device)
        val resp = runCatching {
            client.post(device.location + "input/$channelId") {
                userAgent("Rigel/1.0")
                contentType(ContentType.Text.Plain)
                setBody(RokuEcp.launchBody(mediaUrl))
            }.status.value
        }.getOrNull()
        Logger.i(tag) { "launch $channelId -> $resp" }
        return resp != null && resp in 200..299
    }

    private suspend fun resolvePlayChannelId(device: RokuDevice): String {
        val xml = runCatching { client.get(device.location + "query/apps").bodyAsText() }.getOrNull()
        if (xml != null) {
            for ((id, name) in RokuEcp.parseApps(xml)) {
                val n = name.lowercase()
                if (n.contains("play on roku") || n.contains("roku media player")) return id
            }
        }
        return RokuEcp.PLAY_ON_ROKU_CHANNEL_ID
    }

    suspend fun keypress(device: RokuDevice, key: String) {
        runCatching {
            client.post(device.location + "keypress/$key") { userAgent("Rigel/1.0") }
        }
    }

    suspend fun play(device: RokuDevice) = keypress(device, "Play")
    suspend fun pause(device: RokuDevice) = keypress(device, "Pause")
    suspend fun stop(device: RokuDevice) = keypress(device, "Home")
}
