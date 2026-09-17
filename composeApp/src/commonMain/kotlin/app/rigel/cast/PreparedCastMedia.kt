package app.rigel.cast

enum class CastMediaKind { VIDEO, AUDIO }
enum class CastMediaOrigin { SOURCE, PROXY }

data class PreparedCastMedia(
    val url: String,
    val title: String,
    val contentType: String,
    val container: String,
    val kind: CastMediaKind,
    val isLive: Boolean,
    val origin: CastMediaOrigin,
)
