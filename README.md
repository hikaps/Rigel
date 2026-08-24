# Rigel

A media player for iOS that plays what the stock player won't — and puts it on the biggest screen in the house.

Rigel plays HTTP(S) and file URLs directly whenever iOS supports the format, and converts the rest (MKV, WebM, AVI, MPEG-TS, FLV, …) with FFmpeg on the device. It discovers TVs and media players on your network and casts to them, streams from a Jellyfin server, and can act as a UPnP renderer that other apps push media to.

## Playback

- Play `http(s)` links, local files, and HLS playlists — entered on the home screen, opened from the share sheet or Files, or handed over by other apps.
- Direct AVPlayer playback when the format fits. Otherwise FFmpeg probes the media and Rigel remuxes or transcodes it to HLS on the fly, served from a local HTTP server — conversion happens on your device.
- External subtitle URLs, Picture in Picture, and background audio.

## Screens & casting

- Cast to DLNA/UPnP renderers, Kodi, Roku, and Chromecast/Google Cast. Devices are discovered automatically via SSDP, Google Cast mDNS, or added manually by IP address.
- AirPlay out to Apple TV and AirPlay-2 TVs, picked from the player screen.
- Remote renderers always receive a LAN-reachable stream URL, never a loopback address.
- Outbound receiver families share the Kotlin `ReceiverAdapter` registry; inbound UPnP renderer mode remains a separate native bridge.

## Sources

- **Jellyfin** — connect to your server, browse and search the library, play on this device, or push a library item to a logged-in client session.

## Integrations

- **`rigel://` x-callback URL scheme** (Nuvio-compatible) — other apps can hand playback to Rigel and get a success callback:

  ```
  rigel://x-callback-url/play?url=<encoded>&filename=<encoded>&sub=<encoded, repeatable>&x-source=<encoded>&x-success=<encoded>
  ```

  The full grammar is documented in-app under Settings → Integration.

- **Renderer mode** — Settings → Renderer turns Rigel into a UPnP renderer. Push media to it from Kodi ("Play using…"), BubbleUPnP, Jellyfin-web, and similar.

## Availability

Rigel is not on the App Store or TestFlight. The [rolling beta IPA](https://github.com/hikaps/Rigel/releases/tag/beta) is development-signed: as published, it installs only on devices registered in the developer's profiles and expires about a week after signing.

To receive rolling beta updates through AltStore Classic or SideStore, add the source manifest:

`https://raw.githubusercontent.com/hikaps/Rigel/develop/altstore/source.json`

The manifest is refreshed by the beta workflow after each successfully signed release. To install the IPA on another device, AltStore or SideStore must re-sign it for that device. A free Apple ID normally requires a refresh about every seven days and is subject to Apple's device and app limits. To build from source instead, see [AGENTS.md](AGENTS.md) for the development setup.

## License

Code is licensed under the [GPL-3.0](LICENSE). The bundled FFmpeg libraries are LGPL-3.0 — see [NOTICE](NOTICE).
