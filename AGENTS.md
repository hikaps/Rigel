# Repository Guidelines

## Project Overview

Rigel is an iOS 16+ media player: Kotlin Multiplatform owns shared domain logic; SwiftUI/UIKit and AVPlayer supply native presentation/playback. It supports URLs/files, FFmpeg-to-HLS conversion, Jellyfin, outbound casting and inbound UPnP renderer mode. JVM is a shared-test target, not desktop UI; no Android target or Compose UI is configured.

## Architecture & Data Flow

```text
URL / share extension / UPnP / Jellyfin item
  → RigelIntake → PlayerController → native probe → output profile / FormatRouter
  → direct playback OR FFmpeg HLS + native HTTP server
  → AVPlayer (local/AirPlay) OR receiver adapter
```

- **Ownership:** `RigelCore` composes shared services. `PlayerController.uiState` (`StateFlow<PlayerUiState>`) owns playback orchestration; `SwiftPlayer` exposes it and `PlayerModel` mirrors it for SwiftUI. Keep routing/lifecycle decisions in Kotlin, not a second Swift playback state machine.
- **Routing:** `FormatRouter` and `output/` profiles decide compatibility. `RouteOverride.DIRECT` permits fallback; it is not a forced bypass. AirPlay uses native playback, not a receiver adapter. Its AAC-only audio policy may require conversion while copying compatible video. External subtitles do not inherently force direct media through a proxy; selecting one on an active proxy rebuilds it.
- **Casting:** `CastDispatcher` uses `ReceiverRegistry`/`ReceiverAdapter` for DLNA, Kodi, Roku and Chromecast. Playback access goes through `CastPlaybackPort`; the cast package must not import the player package. Commit sessions only on `CastResult.Sent`, retaining epoch guards against stale completions. Selected output and active cast ownership are distinct.
- **Remote delivery:** receivers and AirPlay proxy playback require LAN-reachable URLs, never loopback. Jellyfin remote sessions require library item IDs and matching server context, not arbitrary URLs.
- **Bridges:** `BridgeRegistry.register()` must run before intake or native actions. Kotlin contracts live in `NativeBridges.kt`; singleton factories expose registered implementations through `BridgeSlot.current`. Missing registration is an explicit failure seam.
- **Lifecycle:** preserve load-generation guards and stop-before-replacement ordering; some native callbacks cannot cancel underlying work. `PlayerHostView` reload identity includes URL, title, sender and AirPlay eligibility. Teardown pauses AVPlayer, invalidates polling, removes the child controller and deactivates the audio session.
- **HLS:** `RigelHlsExporter` owns session serial queues. Delete output only after the writer exits; startup sweeping in `BridgeRegistry.register()` handles abandoned directories. Preserve A/V/subtitle clock alignment and absolute-media versus proxy-relative seek offsets. AirPlay VOD readiness waits for completed output.
- **Audio-session policy:** `longFormVideoAirPlayEligible` requires playing direct video, no proxy, a known non-live/non-HLS probe and duration ≥60 seconds. Other media keeps the default route-sharing policy.

## Key Directories

| Path | Purpose |
| --- | --- |
| `composeApp/src/commonMain/kotlin/app/rigel/` | Shared intake, player, output profiles, routing, settings, discovery, cast protocols and Jellyfin. |
| `composeApp/src/iosMain/kotlin/app/rigel/` | iOS actuals and Swift-facing facades, including `bridge/SwiftPlayer.kt`. |
| `composeApp/src/jvmMain/` | Actuals/dependencies for the shared test target. |
| `composeApp/src/commonTest/kotlin/app/rigel/` | Shared domain and protocol tests. |
| `iosApp/iosApp/` | App/models; `Views/` for presentation, `Services/` for non-view logic, `Bridge/` for native implementations, `Bridge/Hls/` for FFmpeg pipelines. |
| `iosApp/ShareExtension/` | Share-to-intake extension. |
| `RigelTests/` | Root-level hosted XCTest suite and generated fixtures. |
| `scripts/`, `.github/workflows/` | Native prerequisites, manifest generation, CI and releases. |

## Development Commands

Run from repository root unless shown otherwise. Use JDK 21. Native tests require Xcode, generated FFmpeg libraries and fixtures; fixture generation requires the `ffmpeg` CLI.

```bash
# JVM tests and coverage gate
./gradlew :composeApp:jvmTest :composeApp:koverVerify --console=plain
# Coverage XML
./gradlew :composeApp:koverVerify :composeApp:koverXmlReport --console=plain
# Shared Kotlin tests on arm64 iOS simulator
./gradlew :composeApp:iosSimulatorArm64Test --console=plain

# Simulator libraries and test media
JOBS=4 ./scripts/build-ffmpeg.sh
./scripts/gen-fixtures.sh
# Device libraries, when needed
SDK=iphoneos JOBS=4 ./scripts/build-ffmpeg.sh

# Regenerate only with vendor libraries and fixtures present
(cd iosApp && xcodegen generate)

xcrun simctl list devices available
xcodebuild test \
  -project iosApp/Rigel.xcodeproj \
  -scheme Rigel \
  -destination "platform=iOS Simulator,id=<available-UDID>" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Use `xcodebuild build` with the same options for a simulator build; run the `Rigel` scheme in Xcode for the app. No dedicated lint/formatter task is configured.

### Branch and PR Workflow

- Branch from current `develop` into a descriptive feature/fix branch and linked worktree per change. Do not commit feature work directly to `develop` or release branch `main`.
- Push and open feature PRs with base **`develop`**. Run affected local checks and wait for required GitHub CI before merging.
- Merge approved feature PRs **on GitHub with squash merge**, not a local merge/fast-forward. Update local `develop` afterward, then remove the merged remote branch/disposable worktree when no longer needed.
- Release through a `develop` → `main` PR, merged **on GitHub with a merge commit**, never squash, after release checks pass.

## Code Conventions & Common Patterns

- Kotlin: official style, PascalCase types, camelCase members, uppercase enum values, immutable data classes and `StateFlow` transitions. Swift: `@State` for local presentation; `@MainActor ObservableObject`/`@Published` for longer-lived screen state.
- Compare Kotlin enums directly in Swift (`phase == .playing`), not `.name` strings. Keep Kotlin scalar conversions and milliseconds↔seconds conversions at bridge boundaries.
- `PlayerController` and `SwiftPlayer` use main-dispatched coroutine scopes. Preserve cancellation and stale-result guards; propagate cancellation when the native contract supports it.
- Swift Jellyfin callers use `Services/JellyfinAsync.swift`: one `Task` handle per operation kind and post-`await` cancellation checks. Reuse it instead of adding raw completion handlers or generation counters to views.
- Preserve nullable/Boolean/error-string contracts and exact protocol payloads. Classify cast outcomes by sealed `CastResult`, never message text.
- Reuse injection seams: `HttpClient`, `SettingsStore(MapSettings)`, capability resolver, playback port and bridge factories. Receiver-family changes span typed targets, registry, capabilities, discovery/persistence and UI.
- Manual-device rows are `kind|usn|location|name`; preserve exact-row removal. Keep Kotlin route-override persistence aligned with the Swift mapping in `Views/SettingsView.swift`.

## Important Files

Shared paths below are relative to `composeApp/src/commonMain/kotlin/app/rigel/`:

- `RigelCore.kt`; `player/PlayerController.kt` — composition root and playback lifecycle.
- `gateway/FormatRouter.kt`; `output/{PlaybackOutput,OutputMediaProfile,ReceiverCapabilityRepository}.kt` — routing, destination identity and capabilities.
- `bridge/{NativeBridges,BridgeSlot,Bridges}.kt` — contracts, registration and suspend wrappers.
- `cast/{CastDispatcher,ReceiverAdapter,ReceiverRegistry,CastSession}.kt` — receiver/session boundaries.
- `devices/DevicesRepository.kt`; `source/jellyfin/JellyfinClient.kt` — discovery and Jellyfin API/session operations.

Native paths below are relative to `iosApp/iosApp/`:

- `RigelApp.swift`, `PlayerModel.swift`, `Views/PlayerHostView.swift`, `Bridge/RigelPlayerViewController.swift` — startup, shared-state projection and AVPlayer hosting.
- `JellyfinViewModel.swift`, `Services/JellyfinAsync.swift` — screen state and async interop.
- `Bridge/{Bridges,BridgeAdapters,Probe,HttpServer,Ssdp,UpnpRendererService,Chromecast}.swift`, `Bridge/Hls/` — native registration, media and networking.

Build authority: `composeApp/build.gradle.kts`, `gradle/libs.versions.toml`, `iosApp/project.yml`, `.github/workflows/*.yml`. Keep README user-facing; prefer scripts/workflows for operational details.

## Runtime/Tooling Preferences

- Use the **Gradle wrapper 9.7.1**, **Kotlin 2.3.0** and **JDK 21**. Targets: JVM, `iosArm64`, `iosSimulatorArm64`. There is no JavaScript package-manager workflow.
- Xcode embeds static `ComposeApp` via `:composeApp:embedAndSignAppleFrameworkForXcode`. Its prebuild sets `JAVA_HOME` with `brew --prefix openjdk@21`; install that Homebrew JDK for native builds.
- Edit `iosApp/project.yml`, then regenerate with **XcodeGen 2.46.0**; do not hand-edit `project.pbxproj`. First populate `iosApp/vendor/` and `RigelTests/Fixtures/`: generating without fixtures silently drops their tracked resource references.
- FFmpeg defaults to **7.1**, arm64 only. Script overrides: `SDK`, `FF_VERSION`, `PREFIX`, `FF_BUILD_DIR`, `JOBS`; CI uses `JOBS=4`. Xcode stages `vendor/ffmpeg-device` for `iphoneos`, otherwise `vendor/ffmpeg`, into `vendor/ffmpeg/current`.
- `.gradle/`, `.kotlin/`, `build/`, DerivedData, `iosApp/vendor/` and `RigelTests/Fixtures/` are disposable/ignored; regenerate rather than commit binaries/fixtures. CI deliberately avoids caching `~/.konan`.
- Workflow overrides control release versions: stable uses `STABLE_VERSION`; beta uses `<BETA_VERSION_PREFIX>.<github.run_number>`, with the run number also as `buildVersion`. Keep beta semantic versions monotonic: SideStore ignores build-only changes; a reset requires reinstalling. `scripts/generate-altstore-source.py` uses Python 3's standard library and reads version metadata from the IPA.

## Testing & QA

- Run affected gates before and after behavior/API changes. Playback/bridge/config changes require both Kotlin test targets and Swift tests. FFmpeg/fixture/project changes also require regenerated prerequisites and native simulator verification.
- Shared tests use `kotlin.test`, Ktor `MockEngine`, inline XML/JSON, `MapSettings` and bridge fakes. Prefer `runTest`, `StandardTestDispatcher`, scheduler draining and virtual time; keep shared unit tests off real networks/timers.
- Bridge factories, `CastDispatcher` installation and `RigelIntake` are mutable global test state. Reset them, Main dispatcher and mutated fake fields in setup/teardown; avoid inheriting test-isolation omissions.
- Swift uses XCTest and `@testable import Rigel`; UI/model cases use `@MainActor`. `RigelTests` is hosted by `Rigel.app`. `ProbeTest` exercises real FFmpeg/HLS lifecycle: use unique session IDs and stop sessions/clean temporary files. `JellyfinAsyncTests` covers the cancellation gate. Restore static URL-protocol handlers after mocked HTTP tests.
- CI gates JVM/Kover, Kotlin iOS simulator tests and unsigned Swift/Xcode simulator tests. Kover requires **60% overall line coverage**; XML reports go to `composeApp/build/reports/kover/`. Native surface changes also need playback/UI smoke verification.
