# Rigel

A media player for iOS that plays what the stock player won't — and puts it on the biggest screen in the house.

Rigel plays HTTP(S) and file URLs directly whenever iOS supports the format, and converts the rest (MKV, WebM, AVI, MPEG-TS, FLV, …) with FFmpeg on the device. It discovers TVs and media players on your network and casts to them, streams from a Jellyfin server, and can act as a UPnP renderer that other apps push media to.

## Playback

- Play `http(s)` links, local files, and HLS playlists — entered on the home screen, opened from the share sheet or Files, or handed over by other apps.
- Direct AVPlayer playback when the format fits. Otherwise FFmpeg probes the media and Rigel remuxes or transcodes it to HLS on the fly, served from a local HTTP server — conversion happens on your device.
- Buffering indicators follow the current media and reset when playback is replaced.
- External subtitle URLs, Picture in Picture, and background audio.
- OpenSubtitles search and downloads from the player subtitle picker; configure the account under Settings, with credentials kept in the iOS Keychain.

## Screens & casting

- Cast to DLNA/UPnP renderers, Kodi, Roku, and Chromecast/Google Cast. Devices are discovered automatically via SSDP, Google Cast mDNS, or added manually by IP address.
- Jellyfin clients appear in Devices after connecting to the server under Sources. Like Jellyfin’s cast picker, Rigel lists sessions the server allows your account to control, excluding Rigel itself; LAN presence alone is not enough. These destinations play Jellyfin library items, not arbitrary URLs.
- AirPlay out to Apple TV and AirPlay-2 TVs, picked from the player screen. Non-AAC audio is converted to AAC for compatibility, copying compatible video without re-encoding it.
- Remote renderers always receive a LAN-reachable stream URL, never a loopback address.
- Outbound receiver families share the Kotlin `ReceiverAdapter` registry; inbound UPnP renderer mode remains a separate native bridge.

## Sources

- **Jellyfin** — connect to your server to see separate Continue Watching and Next Up feeds, or search and filter the library, browse search-result folders, and play here or push to a logged-in client session. A version picker appears only when an item has multiple media sources. Playback negotiates the chosen source through Jellyfin PlaybackInfo, honoring the server's direct-play/transcoding support and carrying its play session and subtitle tracks through to native playback. The access token is stored in the iOS Keychain; failed credential removal preserves the account and selected destination and reports a secure-storage error.
- Each home feed loads, reports errors, and retries independently. Switching Jellyfin accounts resets feed and folder state and discards in-flight responses and version lookups from the previous account.
- Search results and folders opened from search retain paging, including pages with no usable entries while more records remain and known totals when later pages omit them.
- Jellyfin history links are restored with the current account. Unsupported credential-only stream links are blocked instead of replaying an embedded token through generic playback.
- Cancelling a Jellyfin version choice returns to browsing without starting playback.

## Integrations

- **`rigel://` x-callback URL scheme** (Nuvio-compatible) — other apps can hand playback to Rigel and get a success callback:

  ```
  rigel://x-callback-url/play?url=<encoded>&filename=<encoded>&sub=<encoded, repeatable>&x-source=<encoded>&x-success=<encoded>
  ```

  The full grammar is documented in-app under Settings → Integration.

- **Renderer mode** — Settings → Renderer turns Rigel into a UPnP renderer. Push media to it from Kodi ("Play using…"), BubbleUPnP, Jellyfin-web, and similar.

## Availability

Rigel is not on the App Store or TestFlight. The stable release is published from [`main`](https://github.com/hikaps/Rigel/releases) and the rolling beta is published from [`develop`](https://github.com/hikaps/Rigel/releases/tag/beta) as a separate **Rigel Beta** app, so both channels can be installed side by side.

Rolling beta versions use `<major>.<minor>.<GitHub run number>`, with the same run number as the build identifier, so AltStore and SideStore recognize each update.

To receive stable and rolling beta updates through AltStore Classic or SideStore, add the source manifest:

`https://raw.githubusercontent.com/hikaps/Rigel/develop/altstore/source.json`

The published IPAs are ad-hoc signed; AltStore or SideStore re-signs them with your own Apple ID during installation. A free Apple ID normally requires a refresh about every seven days and is subject to Apple's device and app limits. To build from source instead, see [AGENTS.md](AGENTS.md) for the development setup.

## License

Code is licensed under the [GPL-3.0](LICENSE). The bundled FFmpeg libraries are LGPL-3.0 — see [NOTICE](NOTICE).
