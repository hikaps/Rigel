package app.rigel.output

import io.ktor.http.Url

object RemoteUrlPolicy {
    fun isReceiverFetchable(sourceUrl: String, profile: OutputMediaProfile): Boolean {
        val url = runCatching { Url(sourceUrl) }.getOrNull() ?: return false
        val scheme = url.protocol.name.lowercase()
        if (scheme !in profile.directSchemes) return false
        if (scheme != "http" && scheme != "https") return false
        val host = url.host.trim().trim('[', ']').lowercase().trimEnd('.')
        if (host.isEmpty() || host == "localhost" || host.endsWith(".localhost")) return false
        if (host == "0.0.0.0" || host == "::" || host == "0:0:0:0:0:0:0:0" || host == "::1") return false
        if (isLoopbackIpv4(host)) return false
        return true
    }

    private fun isLoopbackIpv4(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size !in 1..4 || parts.any { it.isEmpty() }) return false
        val values = parts.map { parseNumericPart(it) ?: return false }
        val address = when (parts.size) {
            1 -> values[0].takeIf { it <= 0xFFFF_FFFFL } ?: return false
            2 -> if (values[0] <= 0xFF && values[1] <= 0xFF_FFFFL) {
                values[0] * 0x1000000L + values[1]
            } else return false
            3 -> if (values[0] <= 0xFF && values[1] <= 0xFF && values[2] <= 0xFFFF) {
                values[0] * 0x1000000L + values[1] * 0x10000L + values[2]
            } else return false
            4 -> if (values.all { it <= 0xFF }) {
                values[0] * 0x1000000L + values[1] * 0x10000L + values[2] * 0x100L + values[3]
            } else return false
            else -> return false
        }
        return address in 0x7F000000L..0x7FFFFFFFL
    }

    private fun parseNumericPart(value: String): Long? {
        val lower = value.lowercase()
        val (digits, radix) = when {
            lower.startsWith("0x") -> lower.substring(2) to 16
            lower.length > 1 && lower.startsWith('0') -> lower.substring(1) to 8
            else -> lower to 10
        }
        if (digits.isEmpty()) return null
        return digits.toLongOrNull(radix)?.takeIf { it >= 0 }
    }
}
