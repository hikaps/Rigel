import Foundation
import AVFoundation
import AVKit
import ComposeApp

/// AVPlayerViewController host with a native overlay top bar (back button,
/// title, sender, AirPlay route button). The player view covers the surface,
/// so these must be UIKit views, not Compose content. AirPlay video handoff
/// and PiP come from AVPlayerViewController/AVPlayerItem automatically.
/// Events fire on the main thread.
final class RigelPlayerViewController: UIViewController {
    private let events: PlayerEvents
    private var player: AVPlayer?
    private var playerVC: AVPlayerViewController?
    private var pollTimer: Timer?
    private var disposed = false
    private var audioSessionActivated = false
    /// AVAudioSession is process-wide: only the last active controller may
    /// deactivate it. A late dismantle of an old controller must not kill the
    /// session a replacement just activated.
    private static var activeAudioSessionCount = 0
    private static let audioSessionLock = NSLock()
    private var notifiedPlaying = false

    /// Configure AVAudioSession for the current media so only eligible
    /// long-form video selects the shared video AirPlay route.
    static func configureAudioSession(
        _ audioSession: AVAudioSession = .sharedInstance(),
        longFormVideoAirPlayEligible: Bool
    ) throws {
        let policy: AVAudioSession.RouteSharingPolicy = longFormVideoAirPlayEligible ? .longFormVideo : .default
        try audioSession.setCategory(.playback, mode: .moviePlayback, policy: policy)
        try audioSession.setActive(true)
    }

    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let titleLabel = UILabel()
    private let senderLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let routePicker = AVRoutePickerView()

    init(events: PlayerEvents) {
        self.events = events
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        pollTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupTopBar()
    }

    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        backButton.tintColor = .white
        backButton.accessibilityLabel = "Back"
        backButton.accessibilityHint = "Return to Rigel"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(backButton)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(titleLabel)

        senderLabel.font = .systemFont(ofSize: 12)
        senderLabel.textColor = .white.withAlphaComponent(0.7)
        senderLabel.lineBreakMode = .byTruncatingTail
        senderLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(senderLabel)

        routePicker.tintColor = .white
        routePicker.accessibilityLabel = "Playback destination"
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(routePicker)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            backButton.widthAnchor.constraint(equalToConstant: 40),
            backButton.heightAnchor.constraint(equalToConstant: 40),

            routePicker.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            routePicker.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            routePicker.widthAnchor.constraint(equalToConstant: 44),
            routePicker.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: routePicker.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: backButton.topAnchor, constant: 1),

            senderLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            senderLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            senderLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            topBar.bottomAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 12),
        ])
    }

    @objc private func backTapped() {
        events.onBack()
    }

    func load(url: String, title: String?, sender: String?, longFormVideoAirPlayEligible: Bool) {
        NSLog("[RigelPlayer] load %@ longFormVideo=%d", url, longFormVideoAirPlayEligible ? 1 : 0)
        titleLabel.text = title ?? url.components(separatedBy: "/").last
        senderLabel.text = sender.map { "via \($0)" }
        guard let avURL = URL(string: url) else {
            events.onError(message: "invalid URL: \(url)")
            return
        }
        tearDownPlayer()
        do {
            try Self.configureAudioSession(
                longFormVideoAirPlayEligible: longFormVideoAirPlayEligible
            )
            audioSessionActivated = true
            Self.audioSessionLock.lock()
            Self.activeAudioSessionCount += 1
            Self.audioSessionLock.unlock()
        } catch {
            NSLog("[RigelPlayer] audio session setup failed: %@", error.localizedDescription)
        }

        disposed = false
        notifiedPlaying = false

        let item = AVPlayerItem(url: avURL)
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p

        let vc = AVPlayerViewController()
        vc.player = p
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.updatesNowPlayingInfoCenter = true
        addChild(vc)
        view.insertSubview(vc.view, at: 0)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.didMove(toParent: self)
        playerVC = vc

        // AVPlayer queues this request until the item is ready. Do not call
        // play() from polling: that would override a user's pause.
        p.play()
        startPolling()
    }

    func stopPlayback() {
        disposed = true
        pollTimer?.invalidate()
        pollTimer = nil
        player?.pause()
        tearDownPlayer()
        deactivateAudioSession()
    }

    private func tearDownPlayer() {
        playerVC?.willMove(toParent: nil)
        playerVC?.view.removeFromSuperview()
        playerVC?.removeFromParent()
        playerVC = nil
        player = nil
    }

    private func deactivateAudioSession() {
        guard audioSessionActivated else { return }
        audioSessionActivated = false
        Self.audioSessionLock.lock()
        Self.activeAudioSessionCount -= 1
        let remaining = Self.activeAudioSessionCount
        Self.audioSessionLock.unlock()
        guard remaining <= 0 else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[RigelPlayer] audio session deactivation failed: %@", error.localizedDescription)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !disposed, let player, let item = player.currentItem else { return }
        switch item.status {
        case .failed:
            let nsErr = item.error as NSError?
            let detail = nsErr?.localizedDescription ?? "Playback failed"
            NSLog("[RigelPlayer] item failed: %@ (domain=%@ code=%ld)", detail, nsErr?.domain ?? "?", nsErr?.code ?? -1)
            // One-shot: stop polling so a `.failed` is delivered exactly once.
            // PlayerController may be auto-falling back to the proxy; repeated
            // delivery would race the proxy build and force an error screen.
            pollTimer?.invalidate()
            pollTimer = nil
            events.onError(message: detail)
        case .readyToPlay:
            if player.timeControlStatus == .playing, !notifiedPlaying {
                notifiedPlaying = true
                NSLog("[RigelPlayer] playing")
                events.onReady()
            }
        default:
            break
        }
    }
}

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
        longFormVideoAirPlayEligible: Bool
    ) {
        vc?.load(
            url: url,
            title: title,
            sender: sender,
            longFormVideoAirPlayEligible: longFormVideoAirPlayEligible
        )
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
