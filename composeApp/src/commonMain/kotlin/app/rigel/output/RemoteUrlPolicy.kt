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
        val first = host.substringBefore('.')
        val ipv4Parts = host.split('.')
        if (ipv4Parts.size == 4 && ipv4Parts.all { it.toIntOrNull() != null }) {
            val firstOctet = first.toInt()
            if (firstOctet == 127) return false
        }
        return true
    }
}
