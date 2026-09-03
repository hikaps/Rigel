package app.rigel.cast

/** Discovered receiver devices, one DTO per cast family. */

/** DLNA MediaRenderer parsed from a UPnP device-description XML. */
data class DlnaDevice(
    val usn: String,
    val location: String,
    val friendlyName: String,
    val controlUrl: String,
    val eventSubUrl: String? = null,
)

/** Kodi with "Allow remote control via HTTP" enabled. */
data class KodiDevice(
    val usn: String,
    val endpoint: String, // http://<host>:8080
    val name: String?,
)

/** Roku with the Play on Roku channel available. */
data class RokuDevice(
    val usn: String,
    val location: String, // http://<ip>:8060/
    val modelName: String?,
)

/** Device discovered through Google Cast mDNS or entered manually. */
data class ChromeDevice(
    val id: String,
    val host: String,
    val port: Int,
    val name: String,
)
