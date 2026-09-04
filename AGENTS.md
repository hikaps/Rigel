# Repository Guidelines

## Project Overview

Rigel is an iOS 16+ media player. Shared Kotlin Multiplatform code owns intake, playback orchestration, routing, settings, discovery, casting, and Jellyfin requests. Native Swift/SwiftUI supplies presentation plus AVPlayer, FFmpeg probing/HLS conversion, LAN HTTP serving, SSDP, and UPnP receive-mode implementations.

The root README is user-facing only (features, usage, availability, license); there is no contributor guide or release procedure. Treat the build files, scripts, and CI workflow as the operational source of truth.

## Branch, Worktree & PR Workflow

- Treat `develop` as the integration base and `main` as the release branch. Do not commit feature work directly to either branch.
- Create one feature/fix branch and linked worktree per change, branched from the current `develop`. Use descriptive names such as `fix-airplay` or `feat/app-icon`.
- Push each feature branch to GitHub and open its pull request with **base `develop`**. Keep the branch/worktree isolated from other features.
- Before merge, run the affected local checks and wait for the required GitHub CI checks: JVM/Kover, iOS Kotlin simulator tests, and Swift/Xcode simulator tests when applicable.
- Merge approved feature PRs **on GitHub using squash merge**. Do not replace the GitHub merge with a local merge/fast-forward; the squash commit on `develop` is the integration history.
- After a PR lands, update local `develop` from `origin/develop`, then remove the merged remote feature branch and its disposable worktree when no longer needed.
- Periodically cut a release by opening a PR from `develop` into `main`. Merge that release PR on GitHub with a **merge commit**, never squash; preserve the full integration history that produced the release. Merge only after release checks pass.

- **AltStore/SideStore beta versions:** SideStore currently detects updates from the semantic `version` and ignores a `buildVersion`-only change. The rolling beta workflow must set the IPA and generated manifest version to `<beta major>.<beta minor>.<github.run_number>` while keeping `buildVersion` equal to the run number. Keep that semantic version monotonic after distribution; a deliberate reset requires beta users to reinstall. Stable releases use the normal `STABLE_VERSION` value in the stable workflow.


## Architecture & Data Flow

- **Ownership:** Kotlin owns playback truth in `PlayerController` / `StateFlow<PlayerUiState>`; SwiftUI mirrors it in `PlayerModel` (`@MainActor`) and forwards actions. Do not create a second playback state machine in Swift.
- **Playback:** `UrlIntake` / `RigelIntake` → `PlayerController` → native `ProbeBridge` → `FormatRouter` → direct AVPlayer **or** FFmpeg HLS proxy + LAN HTTP server → `PlayerHostView` / `RigelPlayerViewController`.
- **Inputs:** plain `http(s)`/file URLs, `rigel://x-callback-url/...`, UPnP `SetAVTransportURI`, and Jellyfin library items all enter the normal intake/playback flow.
- **Remote casting:** `CastDispatcher` delegates to the Kotlin `ReceiverAdapter` registry for DLNA/Kodi/Roku/Chromecast and returns sealed `CastResult` (a session commits only on `.Sent`). It touches playback exclusively through `CastPlaybackPort` (implemented by `PlayerController`, wired together with the default `HttpClient` via `CastDispatcher.install(...)` in `RigelCore`), so the cast package never imports the player package. A proxy URL must be re-hosted at the current LAN base; remote renderers must never receive loopback URLs.
- **Bridges:** `NativeBridges.kt` defines native contracts; every native bridge registers into a `BridgeSlot<T>` singleton (`RigelBridgeFactory`, `PlayerBridgeFactory`, `RendererBridgeFactory`, `ChromecastBridgeFactory` — read via `.current`). `BridgeRegistry.register()` in `iosApp/iosApp/Bridge/Bridges.swift` must run before intake, probe, discovery, or renderer actions.
- **Player lifecycle:** `PlayerHostView`'s Coordinator reload guard includes URL, title, sender, and AirPlay eligibility. Native teardown must pause AVPlayer, invalidate the poll timer, remove the child controller, and deactivate the audio session. HLS proxy session directories (`Documents/proxy/<sessionId>/`) are deleted by `RigelHlsExporter.stopSession` from the session's serial queue — strictly after the writer exits — with a startup sweep in `BridgeRegistry.register()` as the crash backstop; never delete them mid-write from the bridge layer.
- **AirPlay:** `longFormVideoAirPlayEligible` is intentionally narrow: playing direct video, no proxy, known non-live/non-HLS probe, duration at least 60 seconds. Keep ineligible media on the default route-sharing policy.

## Key Directories

- `composeApp/src/commonMain/kotlin/app/rigel/` — shared domain logic: intake, player, gateway, settings, devices, cast protocols, Jellyfin.
- `composeApp/src/iosMain/kotlin/app/rigel/` — iOS actuals and Kotlin-to-Swift facades such as `bridge/SwiftPlayer.kt`.
- `composeApp/src/jvmMain/` — JVM-only actuals/dependencies needed by the shared test target; not desktop product UI.
- `composeApp/src/commonTest/kotlin/app/rigel/` — deterministic shared contracts for routing, adapters, discovery, settings, intake, player, and Jellyfin.
- `iosApp/iosApp/` — SwiftUI app shell (`RigelApp.swift`, `PlayerModel.swift`, `JellyfinViewModel.swift`), screens and sheets under `Views/`, non-view services under `Services/` (`OpenSubtitles`, `SubtitlePreferences`, `JellyfinSupport`, `JellyfinAsync`), and native bridges under `Bridge/` (HLS pipeline in `Bridge/Hls/`, KMP adapter classes in `Bridge/BridgeAdapters.swift`).
- `RigelTests/` — XCTest suite for Swift state mapping, AVAudioSession policy, FFmpeg probe, HTTP server, and SSDP.
- `scripts/` — reproducible FFmpeg and media-fixture generation.
- `iosApp/project.yml` — declarative XcodeGen source; `iosApp/Rigel.xcodeproj/` is checked-in generated output.

## Development Commands

Use the Gradle wrapper. CI uses JDK 21.

```bash
# JVM shared tests and Kover gate
./gradlew :composeApp:jvmTest :composeApp:koverVerify --console=plain

# Generate/uploadable JVM coverage report
./gradlew :composeApp:koverVerify :composeApp:koverXmlReport --console=plain

# Kotlin/Native shared tests on an iOS simulator
./gradlew :composeApp:iosSimulatorArm64Test --console=plain

# Build ignored arm64 simulator FFmpeg libraries
./scripts/build-ffmpeg.sh

# Build ignored arm64 device FFmpeg libraries
SDK=iphoneos ./scripts/build-ffmpeg.sh

# Generate ignored XCTest media fixtures
./scripts/gen-fixtures.sh
```

For the Swift suite, install JDK 21 and the `ffmpeg` CLI, run both generation scripts, then use an available iPhone simulator:

```bash
xcodebuild test \
  -project iosApp/Rigel.xcodeproj \
  -scheme Rigel \
  -destination "platform=iOS Simulator,name=<available iPhone>" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Run the `Rigel` scheme from Xcode for the app surface. No dedicated formatter or lint task is documented; do not invent one.

## Code Conventions & Common Patterns

- Kotlin: PascalCase types, camelCase members, uppercase enum values; prefer immutable data classes and `StateFlow` state transitions.
- Swift: SwiftUI local presentation state uses `@State`; screen state that outlives a body lives in a `@MainActor` `ObservableObject` view model (see `JellyfinViewModel`). Call Kotlin client APIs through the `JellyfinAsync` facade (one `Task` handle per operation kind, `Task.isCancelled` checks after each `await`) instead of raw completion handlers and generation counters. Compare Kotlin enums directly in Swift (`phase == .playing`); never round-trip `.name` strings.
- Async: `PlayerController` and `SwiftPlayer` use main-dispatched coroutine scopes. Native bridges convert callbacks to cancellable suspend calls (`invokeOnCancellation` where the contract allows; otherwise document why cancellation cannot propagate). Preserve cancellation, dispatcher, and lifecycle behavior.
- Errors: preserve observable nullable/Boolean/error-string contracts and exact adapter protocol payloads. Cast adapters return sealed `CastResult` — never classify results by message text. Missing native bridge registration is an explicit failure seam, not a condition to silently ignore.
- Test seams: inject `HttpClient` where available (for example `CastDispatcher.cast(..., client)`), use `SettingsStore(MapSettings)`, `MockEngine`, and bridge fakes. Do not add real socket, timer, or network dependencies to unit tests.
- Persisted manual-device rows are `kind|usn|location|name`; preserve that shape and exact-row removal semantics.
- Jellyfin remote sessions accept library item IDs, not arbitrary URLs.

## Important Files

- `composeApp/src/commonMain/kotlin/app/rigel/player/PlayerController.kt` — playback phases, proxy lifecycle, AirPlay eligibility, `CastPlaybackPort` implementation.
- `composeApp/src/commonMain/kotlin/app/rigel/gateway/FormatRouter.kt` — direct/remux/transcode policy.
- `composeApp/src/commonMain/kotlin/app/rigel/bridge/NativeBridges.kt`, `BridgeSlot.kt`, and `Bridges.kt` — platform boundary contracts, registration slots, and suspend wrappers.
- `composeApp/src/commonMain/kotlin/app/rigel/cast/CastDispatcher.kt` — LAN-safe remote URL logic, cast dispatch, sealed `CastResult`.
- `iosApp/iosApp/RigelApp.swift` — startup ordering, bridge registration, URL handling.
- `iosApp/iosApp/PlayerModel.swift`, `Views/PlayerHostView.swift` — Kotlin-state mirroring and native-player hosting.
- `iosApp/iosApp/JellyfinViewModel.swift`, `Services/JellyfinAsync.swift` — Jellyfin screen state and the Kotlin completion-handler → async/await bridge.
- `iosApp/iosApp/Bridge/RigelPlayerViewController.swift` — AVPlayer, external playback, PiP, audio session, polling, teardown.
- `iosApp/iosApp/Bridge/{Probe,HttpServer,Ssdp,UpnpRendererService,Chromecast}.swift` and `Bridge/Hls/` — FFmpeg/network-native responsibilities (the HLS exporter is split across `Bridge/Hls/`).
- `composeApp/build.gradle.kts`, `gradle/libs.versions.toml`, `iosApp/project.yml`, `.github/workflows/ci.yml` — build/dependency/CI authority.

## Runtime/Tooling Preferences

- **Gradle/Kotlin:** Gradle wrapper 9.7.1; Kotlin Multiplatform targets JVM, `iosArm64`, and `iosSimulatorArm64`. Use JDK 21.
- **iOS:** Xcode project targets iOS 16. The app embeds `RigelShare`; `RigelTests` is hosted by `Rigel.app`.
- **XcodeGen:** change `iosApp/project.yml` first, then regenerate the tracked Xcode project with **XcodeGen 2.46.0**: `cd iosApp && xcodegen generate`. Regenerate only with `iosApp/vendor/` present and `RigelTests/Fixtures/` populated (run `scripts/gen-fixtures.sh` first on a fresh checkout): the tracked pbxproj lists the gitignored fixture files, and generating without them silently drops them from the project — the test target then fails its resource phase until fixtures are generated. Avoid hand-editing `project.pbxproj`.
- **FFmpeg:** `iosApp/vendor/` is ignored. The app prebuild stages `ffmpeg-device` for `iphoneos` and `ffmpeg` otherwise into `vendor/ffmpeg/current`; it then embeds the static `ComposeApp` framework through Gradle.
- **Generated data:** `.gradle/`, `build/`, `DerivedData/`, `iosApp/vendor/`, and `RigelTests/Fixtures/` are disposable. Regenerate vendor libraries and fixtures rather than committing them.

## Testing & QA

- Kotlin tests use `kotlin.test` in `commonTest`; HTTP tests use Ktor `MockEngine`, protocol tests use inline XML/JSON fixtures, and async tests use `runTest`, `StandardTestDispatcher`, `Dispatchers.setMain/resetMain`, and scheduler draining.
- Bridge factories, `CastDispatcher` install state, and `RigelIntake` are global mutable test state. Register/install fakes deliberately and reset them all in setup/teardown (also restore any fixture fields a test mutates); avoid test-order coupling. Swift-side Kotlin fakes use `@testable import Rigel`.
- Swift tests use XCTest (`@MainActor` where UI model state is exercised). `ProbeTest` requires generated FFmpeg media resources and also covers HLS session lifecycle including directory cleanup; `JellyfinAsyncTests` covers the Kotlin completion-handler → async cancellation gate.
- CI gates three paths: JVM tests plus Kover XML report, Kotlin iOS simulator tests, and unsigned Swift/Xcode simulator tests. Kover enforces **60% overall line coverage**.
- Before a behavior or API change, run the affected target(s). For playback/bridge/config changes, run both Kotlin test targets and the Swift suite; for FFmpeg/fixture/project changes, regenerate prerequisites and exercise `xcodebuild test`.
