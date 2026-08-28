package app.rigel.intake

import app.rigel.bridge.SubtitleTrack

import co.touchlab.kermit.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Parses rigel:// x-callback URLs and plain http(s)/file URLs.
 * Grammar: rigel://x-callback-url/{play|stream}?url=<enc>&filename=<enc>
 *          &sub=<enc,repeatable>&x-source=<enc>&x-success=<enc>
 * Pure function on the input string — unit-tested.
 */
data class IntakeRequest(
    val sourceUrl: String,
    val filename: String?,
    val subtitleTracks: List<SubtitleTrack>,
    val successCallbackUrl: String?,
    val xSource: String? = null,
    val title: String? = null,
)

object UrlIntake {
    private const val TAG = "UrlIntake"

    private val actions = setOf("x-callback-url/play", "x-callback-url/stream")

    fun parse(raw: String): IntakeRequest? {
        val trimmed = raw.trim()
        return when {
            trimmed.startsWith("rigel://", ignoreCase = true) -> parseRigel(trimmed)
            trimmed.startsWith("http://") || trimmed.startsWith("https://") || trimmed.startsWith("file://") ->
                IntakeRequest(trimmed, null, emptyList(), null)
            else -> null
        }
    }

    private fun parseRigel(uri: String): IntakeRequest? {
        val rest = uri.removePrefix("rigel://").removePrefix("RIGEL://")
        val hostAndPath = rest.substringBefore('?')
        if (hostAndPath !in actions) return null
        val query = rest.substringAfter('?', "")
        if (query.isEmpty()) return null
        val params = parseQuery(query)
        val sourceUrl = params["url"]?.firstOrNull()
            ?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
            ?: return null
        val subtitleTracks = params["sub"].orEmpty()
            .filter { it.startsWith("http://") || it.startsWith("https://") }
            .map { SubtitleTrack(url = it) }
        val filename = params["filename"]?.firstOrNull()
        val success = params["x-success"]?.firstOrNull()
            ?.takeIf { it.startsWith("http://") || it.startsWith("https://") }
        val xSource = params["x-source"]?.firstOrNull()?.takeIf { it.isNotBlank() }
        return IntakeRequest(sourceUrl, filename, subtitleTracks, success, xSource)
    }

    /** Query-string parsing: '&' separators, '+' = space, %XX percent-decode. */
    internal fun parseQuery(query: String): Map<String, List<String>> {
        val out = LinkedHashMap<String, MutableList<String>>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val key = percentDecode(if (eq >= 0) pair.substring(0, eq) else pair)
            val value = percentDecode(if (eq >= 0) pair.substring(eq + 1) else "")
            out.getOrPut(key) { mutableListOf() }.add(value)
        }
        return out
    }

    internal fun percentDecode(s: String): String {
        if ('%' !in s && '+' !in s) return s
        val bytes = ArrayList<Byte>(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '%' && i + 2 < s.length -> {
                    val hex = s.substring(i + 1, i + 3)
                    val value = hex.toIntOrNull(16)
                    if (value != null) {
                        bytes.add(value.toByte())
                        i += 3
                    } else {
                        bytes.addAll(c.toString().encodeToByteArray().toList())
                        i += 1
                    }
                }
                c == '+' -> {
                    bytes.add(' '.code.toByte())
                    i += 1
                }
                else -> {
                    bytes.addAll(c.toString().encodeToByteArray().toList())
                    i += 1
                }
            }
        }
        return bytes.toByteArray().decodeToString()
    }

    private val successScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val client by lazy { HttpClient() }

    /** Fire-and-forget x-success callback (plain GET, no params). */
    fun fireSuccess(callbackUrl: String?) {
        if (callbackUrl.isNullOrBlank()) return
        successScope.launch {
            runCatching { client.get(callbackUrl) }
                .onSuccess { Logger.i(TAG) { "x-success fired: $callbackUrl (${it.status})" } }
                .onFailure { Logger.w(TAG, it) { "x-success failed: $callbackUrl" } }
        }
    }
}
