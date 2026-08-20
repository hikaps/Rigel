package app.rigel.cast.roku

/**
 * Pure builders/parsers for Roku ECP (External Control Protocol).
 * Reference: Home Assistant components/roku + Roku ECP docs.
 */
object RokuEcp {
    /** "Play on Roku" channel id. Verify against developer.roku.com at runtime. */
    const val PLAY_ON_ROKU_CHANNEL_ID = "15985"

    data class DeviceInfo(
        val hasPlayOnRoku: Boolean,
        val modelName: String?,
    )

    fun launchBody(mediaUrl: String): String = "t=${formEncode(mediaUrl)}"

    fun parseDeviceInfo(xml: String): DeviceInfo? {
        if (!xml.contains("<device-info")) return null
        val hasPlayOnRoku = Regex("""<has-play-on-roku>\s*([^<]+?)\s*</has-play-on-roku>""")
            .find(xml)?.groupValues?.get(1)?.trim()?.equals("true", ignoreCase = true) ?: false
        val modelName = Regex("""<model-name>\s*([^<]+?)\s*</model-name>""")
            .find(xml)?.groupValues?.get(1)?.trim()
        return DeviceInfo(hasPlayOnRoku, modelName)
    }

    /** Parse /query/apps response: app id → name. */
    fun parseApps(xml: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (m in Regex("""<app id="([^"]+)">([^<]*)</app>""").findAll(xml)) {
            out[m.groupValues[1]] = m.groupValues[2].trim()
        }
        return out
    }

    internal fun formEncode(s: String): String {
        val sb = StringBuilder(s.length)
        for (byte in s.encodeToByteArray()) {
            val c = byte.toInt() and 0xFF
            val keep = (c in 'a'.code..'z'.code) ||
                (c in 'A'.code..'Z'.code) ||
                (c in '0'.code..'9'.code) ||
                c == '-'.code || c == '_'.code || c == '.'.code || c == '~'.code
            if (keep) {
                sb.append(c.toChar())
            } else {
                sb.append('%').append((c ushr 4).toString(16).uppercase())
                    .append((c and 0x0F).toString(16).uppercase())
            }
        }
        return sb.toString()
    }
}
