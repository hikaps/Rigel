package app.rigel.output

import app.rigel.cast.CastTarget

/** How strongly a receiver profile constrains direct playback. */
enum class ReceiverCompatibilityMode {
    DECLARED,
    CONSERVATIVE,
    OPTIMISTIC_HTTP,
}

enum class CapabilitySource {
    ADVERTISED,
    FAMILY_DEFAULT,
}

data class OutputMediaProfile(
    val mode: ReceiverCompatibilityMode,
    val source: CapabilitySource,
    val directSchemes: Set<String>,
    val directContainers: Set<String>,
    val directVideoCodecs: Set<String>,
    val directAudioCodecs: Set<String>,
    val directPixelFormats: Set<String>,
    val hlsVideoCodecs: Set<String>,
    val hlsAudioCodecs: Set<String>,
    val supportsHlsWebVtt: Boolean,
    val maxWidth: Int? = null,
    val maxHeight: Int? = null,
    val maxFrameRate: Double? = null,
    val maxH264Level: Int? = null,
    val detail: String,
)

object OutputMediaProfiles {
    private val h264Pixels = setOf("yuv420p", "nv12")
    private val h264 = setOf("h264")
    private val aac = setOf("aac")

    val local = OutputMediaProfile(
        mode = ReceiverCompatibilityMode.CONSERVATIVE,
        source = CapabilitySource.FAMILY_DEFAULT,
        directSchemes = setOf("http", "https", "file"),
        directContainers = setOf("mp4", "mov", "m3u8", "hls"),
        directVideoCodecs = h264,
        directAudioCodecs = setOf("aac", "mp3", "flac", "alac"),
        directPixelFormats = h264Pixels,
        hlsVideoCodecs = h264,
        hlsAudioCodecs = aac,
        supportsHlsWebVtt = true,
        detail = "This iPhone",
    )

    fun conservativeReceiver(name: String, detail: String = "") = OutputMediaProfile(
        mode = ReceiverCompatibilityMode.CONSERVATIVE,
        source = CapabilitySource.FAMILY_DEFAULT,
        directSchemes = setOf("http", "https"),
        directContainers = setOf("mp4", "mov", "m4v", "m3u8", "hls"),
        directVideoCodecs = h264,
        directAudioCodecs = aac,
        directPixelFormats = h264Pixels,
        hlsVideoCodecs = h264,
        hlsAudioCodecs = aac,
        supportsHlsWebVtt = true,
        maxWidth = 1920,
        maxHeight = 1080,
        maxFrameRate = 30.0,
        maxH264Level = 41,
        detail = detail.ifBlank { name },
    )

    fun optimisticHttp(name: String) = OutputMediaProfile(
        mode = ReceiverCompatibilityMode.OPTIMISTIC_HTTP,
        source = CapabilitySource.FAMILY_DEFAULT,
        directSchemes = setOf("http", "https"),
        directContainers = emptySet(),
        directVideoCodecs = emptySet(),
        directAudioCodecs = emptySet(),
        directPixelFormats = emptySet(),
        hlsVideoCodecs = h264,
        hlsAudioCodecs = aac,
        supportsHlsWebVtt = true,
        maxWidth = 1920,
        maxHeight = 1080,
        maxFrameRate = 30.0,
        maxH264Level = 41,
        detail = name,
    )

    fun airPlay(name: String) = optimisticHttp(name.ifBlank { "AirPlay" }).copy(
        directSchemes = setOf("http", "https", "file"),
        detail = name.ifBlank { "AirPlay" },
    )

    fun familyDefault(target: CastTarget): OutputMediaProfile = when (target) {
        is CastTarget.Dlna -> conservativeReceiver(target.name, "DLNA compatibility profile")
        is CastTarget.Roku -> conservativeReceiver(target.name, "Roku compatibility profile")
        is CastTarget.Chrome -> conservativeReceiver(target.name, "Chromecast compatibility profile")
        is CastTarget.Kodi -> optimisticHttp(target.name)
        is CastTarget.JellyfinSessionTarget -> optimisticHttp(target.name)
    }
}
