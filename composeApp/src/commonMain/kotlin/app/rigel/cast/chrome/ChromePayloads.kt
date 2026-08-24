package app.rigel.cast.chrome

object ChromePayloads {
    const val NS_CONNECTION = "urn:x-cast:com.google.cast.tp.connection"
    const val NS_HEARTBEAT = "urn:x-cast:com.google.cast.tp.heartbeat"
    const val NS_RECEIVER = "urn:x-cast:com.google.cast.receiver"
    const val NS_MEDIA = "urn:x-cast:com.google.cast.media"
    const val DEFAULT_MEDIA_APP_ID = "CC1AD845"

    fun connect(requestId: Int): String = """{"type":"CONNECT"}"""

    fun launch(appId: String, requestId: Int): String =
        """{"type":"LAUNCH","appId":"${jsonEscape(appId)}","requestId":$requestId}"""

    fun getStatus(requestId: Int): String =
        """{"type":"GET_STATUS","requestId":$requestId}"""

    fun ping(requestId: Int): String =
        """{"type":"PING","requestId":$requestId}"""

    fun pong(requestId: Int): String =
        """{"type":"PONG","requestId":$requestId}"""

    fun load(url: String, title: String, contentType: String, requestId: Int): String =
        """{"type":"LOAD","requestId":$requestId,"autoplay":true,"currentTime":0,"media":{"contentId":"${jsonEscape(url)}","streamType":"BUFFERED","contentType":"${jsonEscape(contentType)}","metadata":{"type":0,"title":"${jsonEscape(title)}"}}}"""

    fun contentTypeFor(url: String): String {
        val extension = url.substringBefore('?').substringBefore('#').substringAfterLast('.').lowercase()
        return when (extension) {
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "m3u8" -> "application/x-mpegurl"
            "ts" -> "video/mp2t"
            "mp3" -> "audio/mpeg"
            "m4a" -> "audio/mp4"
            "aac" -> "audio/aac"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            else -> "video/mp4"
        }
    }

    fun extractTransportId(receiverStatusJson: String): String? =
        Regex("\\\"transportId\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"")
            .find(receiverStatusJson)?.groupValues?.getOrNull(1)
    fun requestId(payload: String): Int? =
        Regex("\\\"requestId\\\"\\s*:\\s*(\\d+)")
            .find(payload)?.groupValues?.getOrNull(1)?.toIntOrNull()

    fun messageType(payload: String): String? = stringField(payload, "type")

    fun errorReason(payload: String): String? = stringField(payload, "reason")

    private fun stringField(json: String, key: String): String? =
        Regex("\\\"${Regex.escape(key)}\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"")
            .find(json)?.groupValues?.getOrNull(1)

    private fun jsonEscape(value: String): String =
        value.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
}
