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
    private var notifiedPlaying = false

    /// Configure AVAudioSession for long-form video so AirPlay routes the
    /// video item, not only its audio track, to the selected receiver.
    static func configureAudioSession(_ audioSession: AVAudioSession = .sharedInstance()) throws {
        try audioSession.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try audioSession.setActive(true)
    }

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
        setupTopBar()
    }

    private func setupTopBar() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: view.topAnchor),
            blur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blur.heightAnchor.constraint(equalToConstant: 96),
        ])

        backButton.setTitle("←", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 24)
        backButton.tintColor = .white
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(backButton)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(titleLabel)

        senderLabel.font = .systemFont(ofSize: 11)
        senderLabel.textColor = .white.withAlphaComponent(0.7)
        senderLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(senderLabel)

        routePicker.tintColor = .white
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(routePicker)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: 20),
            backButton.widthAnchor.constraint(equalToConstant: 40),
            backButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: routePicker.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: 8),

            senderLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            senderLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: routePicker.leadingAnchor, constant: -8),

            routePicker.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            routePicker.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: 20),
            routePicker.widthAnchor.constraint(equalToConstant: 44),
            routePicker.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func backTapped() {
        events.onBack()
    }

    func load(url: String, title: String?, sender: String?) {
        NSLog("[RigelPlayer] load %@", url)
        titleLabel.text = title ?? url.components(separatedBy: "/").last
        senderLabel.text = sender.map { "via \($0)" }
        guard let avURL = URL(string: url) else {
            events.onError(message: "invalid URL: \(url)")
            return
        }
        tearDownPlayer()
        do {
            try Self.configureAudioSession()
            audioSessionActivated = true
        } catch {
            NSLog("[RigelPlayer] audio session setup failed: %@", error.localizedDescription)
        }

        notifiedPlaying = false

        let item = AVPlayerItem(url: avURL)
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p

        let vc = AVPlayerViewController()
        vc.player = p
        vc.allowsPictureInPicturePlayback = true
        addChild(vc)
        view.insertSubview(vc.view, at: 0)
        vc.view.frame = view.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.didMove(toParent: self)
        playerVC = vc

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
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[RigelPlayer] audio session deactivation failed: %@", error.localizedDescription)
        }
        audioSessionActivated = false
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
            events.onError(message: detail)
        case .readyToPlay:
            if player.timeControlStatus == .playing {
                if !notifiedPlaying {
                    notifiedPlaying = true
                    NSLog("[RigelPlayer] playing")
                }
                events.onReady()
            } else {
                player.play()
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

    func load(url: String, title: String?, sender: String?) {
        vc?.load(url: url, title: title, sender: sender)
    }

    func stop() {
        vc?.stopPlayback()
    }
}
