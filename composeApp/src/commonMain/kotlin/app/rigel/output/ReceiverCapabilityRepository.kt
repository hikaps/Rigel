package app.rigel.output

import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverRegistry
import app.rigel.cast.ChromeDevice
import app.rigel.cast.DlnaDevice
import app.rigel.cast.KodiDevice
import app.rigel.cast.RokuDevice
import io.ktor.client.HttpClient
import kotlin.time.TimeSource

interface OutputCapabilityResolver {
    suspend fun profileFor(target: CastTarget): OutputMediaProfile
    fun invalidate(target: CastTarget)
}

/** Volatile receiver-profile cache; persisted manual rows remain identity-only. */
class ReceiverCapabilityRepository(
    private val client: HttpClient,
    private val clockMillis: (() -> Long)? = null,
) : OutputCapabilityResolver {
    private data class Key(val identity: String, val fingerprint: String)
    private data class Entry(val profile: OutputMediaProfile, val expiresAt: Long)

    private val monotonicStart = TimeSource.Monotonic.markNow()
    private val entries = mutableMapOf<Key, Entry>()

    override suspend fun profileFor(target: CastTarget): OutputMediaProfile {
        val key = Key(target.identityKey, fingerprint(target))
        val now = nowMillis()
        entries[key]?.takeIf { it.expiresAt > now }?.let { return it.profile }

        val profile = runCatching {
            ReceiverRegistry.adapterFor(target).mediaProfile(target, client)
        }.getOrElse { OutputMediaProfiles.familyDefault(target) }
        val ttl = if (profile.source == CapabilitySource.ADVERTISED) SUCCESS_TTL else FALLBACK_TTL
        entries[key] = Entry(profile, now + ttl)
        return profile
    }

    override fun invalidate(target: CastTarget) {
        entries.keys.removeAll { it.identity == target.identityKey }
    }

    private fun nowMillis(): Long = clockMillis?.invoke() ?: monotonicStart.elapsedNow().inWholeMilliseconds

    private fun fingerprint(target: CastTarget): String = when (target) {
        is CastTarget.Dlna -> {
            val d: DlnaDevice = target.device
            "\${d.location}|\${d.controlUrl}|\${d.friendlyName}"
        }
        is CastTarget.Roku -> {
            val d: RokuDevice = target.device
            "\${d.location}|\${d.modelName}"
        }
        is CastTarget.Kodi -> {
            val d: KodiDevice = target.device
            d.endpoint
        }
        is CastTarget.Chrome -> {
            val d: ChromeDevice = target.device
            "\${d.host}:\${d.port}|\${d.name}"
        }
        is CastTarget.JellyfinSessionTarget -> target.serverBase
    }

    private companion object {
        const val SUCCESS_TTL = 10 * 60 * 1000L
        const val FALLBACK_TTL = 60 * 1000L
    }
}
