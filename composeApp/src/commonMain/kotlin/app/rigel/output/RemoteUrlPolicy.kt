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
        if (canonicalIpAddress(host)?.isLoopbackOrUnspecified == true) return false
        return true
    }
}

/** Canonical numeric host representation shared by URL policy and discovery. */
internal data class CanonicalIpAddress(
    val text: String,
    private val groups: List<Int>,
) {
    val isLoopbackOrUnspecified: Boolean
        get() {
            if (groups.size == 4) {
                val address = groups[0] * 0x1000000L + groups[1] * 0x10000L +
                    groups[2] * 0x100L + groups[3]
                return address == 0L || address in 0x7F000000L..0x7FFFFFFFL
            }
            if (groups.all { it == 0 } || (groups.take(7).all { it == 0 } && groups[7] == 1)) {
                return true
            }
            if (groups.take(5).all { it == 0 } &&
                (groups[5] == 0 || groups[5] == 0xFFFF)
            ) {
                val address = groups[6] * 0x10000L + groups[7]
                return address == 0L || address in 0x7F000000L..0x7FFFFFFFL
            }
            return false
        }
}

internal fun canonicalIpAddress(raw: String): CanonicalIpAddress? {
    val host = raw.trim().trim('[', ']')
    if (host.contains(':')) {
        val groups = parseIpv6(host) ?: return null
        return CanonicalIpAddress(groups.joinToString(":") { it.toString(16) }, groups)
    }
    val address = parseIpv4(host) ?: return null
    val groups = listOf(
        ((address shr 24) and 0xFF).toInt(),
        ((address shr 16) and 0xFF).toInt(),
        ((address shr 8) and 0xFF).toInt(),
        (address and 0xFF).toInt(),
    )
    return CanonicalIpAddress(groups.joinToString("."), groups)
}

private fun parseIpv4(host: String): Long? {
    val parts = host.split('.')
    if (parts.size !in 1..4 || parts.any { it.isEmpty() }) return null
    val values = parts.map { parseNumericPart(it) ?: return null }
    val address = when (parts.size) {
        1 -> values[0].takeIf { it <= 0xFFFF_FFFFL }
        2 -> if (values[0] <= 0xFF && values[1] <= 0xFF_FFFFL) {
            values[0] * 0x1000000L + values[1]
        } else null
        3 -> if (values[0] <= 0xFF && values[1] <= 0xFF && values[2] <= 0xFFFF) {
            values[0] * 0x1000000L + values[1] * 0x10000L + values[2]
        } else null
        4 -> if (values.all { it <= 0xFF }) {
            values[0] * 0x1000000L + values[1] * 0x10000L + values[2] * 0x100L + values[3]
        } else null
        else -> null
    }
    return address
}

private fun parseIpv6(host: String): List<Int>? {
    val compression = host.indexOf("::")
    if (compression >= 0 && host.indexOf("::", compression + 2) >= 0) return null
    val leftText = if (compression >= 0) host.substring(0, compression) else host
    val rightText = if (compression >= 0) host.substring(compression + 2) else ""
    val left = parseIpv6Part(leftText) ?: return null
    val right = parseIpv6Part(rightText) ?: return null
    if (compression < 0) return left.takeIf { it.size == 8 }
    val missing = 8 - left.size - right.size
    if (missing <= 0) return null
    return left + List(missing) { 0 } + right
}

private fun parseIpv6Part(part: String): List<Int>? {
    if (part.isEmpty()) return emptyList()
    val groups = mutableListOf<Int>()
    val tokens = part.split(':')
    for ((index, token) in tokens.withIndex()) {
        if (token.contains('.')) {
            if (index != tokens.lastIndex) return null
            val octets = token.split('.')
            if (octets.size != 4 || octets.any { parseNumericPart(it)?.takeIf { value -> value <= 0xFF } == null }) {
                return null
            }
            val address = parseIpv4(token) ?: return null
            groups += ((address shr 16) and 0xFFFF).toInt()
            groups += (address and 0xFFFF).toInt()
        } else {
            if (token.isEmpty() || token.length > 4) return null
            groups += token.toIntOrNull(16) ?: return null
        }
    }
    return groups
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
