import Foundation
import AVKit
import UIKit
import ComposeApp

final class RigelPlayerBridge: NSObject, NativePlayerBridge {
    private var vc: RigelPlayerViewController?

    func createPlayerViewController(events: PlayerEvents) -> UIViewController {
        let v = RigelPlayerViewController(events: events)
        vc = v
        return v
    }

    func load(
        url: String,
        title: String?,
        sender: String?,
        longFormVideoAirPlayEligible: Bool,
        subtitleTracks: [SubtitleTrack],
        selectedExternalSubtitleUrl: String?,
        durationMs: KotlinLong?,
        isProxy: Bool,
        startOffsetMs: Int64
    ) {
        vc?.load(
            url: url,
            title: title,
            sender: sender,
            longFormVideoAirPlayEligible: longFormVideoAirPlayEligible,
            subtitleTracks: subtitleTracks,
            selectedExternalSubtitleUrl: selectedExternalSubtitleUrl,
            durationSeconds: durationMs.map { $0.doubleValue / 1000.0 },
            isProxy: isProxy,
            startOffsetSeconds: Double(startOffsetMs) / 1000.0
        )
    }

    func isCurrent(viewController: RigelPlayerViewController) -> Bool {
        vc === viewController
    }

    func stop() {
        vc?.stopPlayback()
        vc = nil
    }

    /// Stops the given controller (per-player disposal is always safe; audio
    /// session release is reference-counted). Returns true only when that
    /// controller was still the bridge's current one, letting callers discard
    /// stale errors from dismantled players.
    @discardableResult
    func stop(viewController: RigelPlayerViewController) -> Bool {
        viewController.stopPlayback()
        guard vc === viewController else { return false }
        vc = nil
        return true
    }
}
