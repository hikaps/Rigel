import Foundation
import AVFoundation
import AVKit
import ComposeApp

/// AVPlayer host with native title, route, audio/subtitle, and transport controls.
/// The overlay chrome follows normal player behavior: it appears on interaction
/// and fades while playback runs. HLS proxy playlists are presented with
/// Rigel's own transport bar because an in-progress VOD playlist is reported by
/// AVPlayer as live and would otherwise hide seeking and skip controls.
/// Direct VOD media keeps AVPlayer's controls. AirPlay video handoff and PiP
/// come from AVPlayerViewController.
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
    private let tracksButton = UIButton(type: .system)
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let progressSlider = UISlider()
    private let skipBackwardButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let elapsedLabel = UILabel()
    private let durationLabel = UILabel()
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var trackGroupsLoadedFor: AVPlayerItem?
    private var customPlaybackControls = false
    private var controlsHideTimer: Timer?
    private var controlsVisible = true


    init(events: PlayerEvents) {
        self.events = events
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        pollTimer?.invalidate()
        controlsHideTimer?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupTopBar()
        setupBottomBar()
        setupControlsGesture()
    }

    private func setupTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.accessibilityIdentifier = "player.topBar"
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

        tracksButton.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        tracksButton.tintColor = .white
        tracksButton.accessibilityLabel = "Audio and subtitles"
        tracksButton.accessibilityHint = "Choose an audio track or subtitle"
        tracksButton.addTarget(self, action: #selector(tracksTapped), for: .touchUpInside)
        tracksButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(tracksButton)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            backButton.widthAnchor.constraint(equalToConstant: 40),
            backButton.heightAnchor.constraint(equalToConstant: 40),

            routePicker.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            routePicker.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            routePicker.widthAnchor.constraint(equalToConstant: 44),
            routePicker.heightAnchor.constraint(equalToConstant: 44),

            tracksButton.trailingAnchor.constraint(equalTo: routePicker.leadingAnchor, constant: -2),
            tracksButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            tracksButton.widthAnchor.constraint(equalToConstant: 40),
            tracksButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: tracksButton.leadingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: backButton.topAnchor, constant: 1),

            senderLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            senderLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            senderLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),


            topBar.bottomAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 12),
        ])
    }
    private func setupBottomBar() {
        bottomBar.accessibilityIdentifier = "player.bottomBar"
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.isHidden = true
        view.addSubview(bottomBar)

        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = .white.withAlphaComponent(0.35)
        progressSlider.addTarget(self, action: #selector(progressChanged), for: .valueChanged)
        progressSlider.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(progressSlider)

        let buttons: [(UIButton, String, String, Selector)] = [
            (skipBackwardButton, "gobackward.15", "Back 15 seconds", #selector(skipBackwardTapped)),
            (playPauseButton, "play.fill", "Play", #selector(playPauseTapped)),
            (skipForwardButton, "goforward.15", "Forward 15 seconds", #selector(skipForwardTapped)),
        ]
        for (button, imageName, label, action) in buttons {
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        playPauseButton.accessibilityHint = "Pause or resume playback"

        for label in [elapsedLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.text = "00:00"
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        durationLabel.textAlignment = .right

        let controls = UIStackView(arrangedSubviews: [
            skipBackwardButton,
            playPauseButton,
            skipForwardButton,
            elapsedLabel,
            UIView(),
            durationLabel,
        ])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = 4
        controls.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(controls)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            progressSlider.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 16),
            progressSlider.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -16),
            progressSlider.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 2),
            controls.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor, constant: -8),
            bottomBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
        ])
    }


    private func setupControlsGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(controlsTapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc private func controlsTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        if topBar.frame.contains(point) || (customPlaybackControls && bottomBar.frame.contains(point)) {
            showControls()
            return
        }
        if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    func showControls() {
        controlsVisible = true
        topBar.isHidden = false
        bottomBar.isHidden = !customPlaybackControls
        scheduleControlsHide()
    }

    func hideControls() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        controlsVisible = false
        topBar.isHidden = true
        if customPlaybackControls {
            bottomBar.isHidden = true
        }
    }

    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        guard controlsVisible, player?.timeControlStatus == .playing else { return }
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    @objc private func backTapped() {
        events.onBack()
    }
    static func fallbackTitle(for rawURL: String) -> String {
        let decoded = rawURL.removingPercentEncoding ?? rawURL
        let component = URL(string: decoded)?.deletingPathExtension().lastPathComponent
            ?? decoded.split(separator: "/").last.map(String.init)
            ?? ""
        let normalized = component.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || ["index", "playlist", "master", "out"].contains(normalized.lowercased()) {
            return "Video"
        }
        return normalized.replacingOccurrences(of: "_", with: " ")
    }

    private static func isHLSURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL) else {
            return rawURL.lowercased().contains(".m3u8")
        }
        return url.pathExtension.lowercased() == "m3u8"
    }

    @objc private func tracksTapped() {
        showControls()
        let alert = UIAlertController(title: "Audio & Subtitles", message: nil, preferredStyle: .actionSheet)
        if let audioGroup, !audioGroup.options.isEmpty {
            for option in audioGroup.options {
                let selected = player?.currentItem?.currentMediaSelection.selectedMediaOption(in: audioGroup) === option
                let title = "\(selected ? "✓ " : "")Audio: \(option.displayName)"
                alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.player?.currentItem?.select(option, in: audioGroup)
                    self?.updateTrackButton()
                })
            }
        }
        if let subtitleGroup, !subtitleGroup.options.isEmpty {
            if subtitleGroup.allowsEmptySelection {
                alert.addAction(UIAlertAction(title: "Subtitles: Off", style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.player?.currentItem?.select(nil, in: subtitleGroup)
                    self.updateTrackButton()
                })
            }
            for option in subtitleGroup.options {
                let selected = player?.currentItem?.currentMediaSelection.selectedMediaOption(in: subtitleGroup) === option
                let title = "\(selected ? "✓ " : "")Subtitles: \(option.displayName)"
                alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.player?.currentItem?.select(option, in: subtitleGroup)
                    self?.updateTrackButton()
                })
            }
        }
        if alert.actions.isEmpty {
            alert.message = "No alternate audio or subtitle tracks are available."
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = tracksButton
            popover.sourceRect = tracksButton.bounds
        }
        present(alert, animated: true)
    }

    private func loadTrackGroups(for item: AVPlayerItem) {
        guard trackGroupsLoadedFor !== item else { return }
        let asset = item.asset
        let key = "availableMediaCharacteristicsWithMediaSelectionOptions"
        asset.loadValuesAsynchronously(forKeys: [key]) { [weak self, weak item] in
            guard let self, let item else { return }
            var error: NSError?
            guard asset.statusOfValue(forKey: key, error: &error) == .loaded else { return }
            let audio = asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
            let subtitles = asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
            DispatchQueue.main.async {
                guard !self.disposed, self.player?.currentItem === item else { return }
                self.audioGroup = audio
                self.subtitleGroup = subtitles
                self.trackGroupsLoadedFor = item
                self.updateTrackButton()
            }
        }
    }

    private func updateTrackButton() {
        let audioCount = audioGroup?.options.count ?? 0
        let subtitleCount = subtitleGroup?.options.count ?? 0
        if audioCount == 0 && subtitleCount == 0 {
            tracksButton.accessibilityValue = "No alternate tracks"
        } else {
            tracksButton.accessibilityValue = "\(audioCount) audio, \(subtitleCount) subtitle"
                + (subtitleCount == 1 ? "" : "s")
        }
    }


    func load(url: String, title: String?, sender: String?, longFormVideoAirPlayEligible: Bool) {
        NSLog("[RigelPlayer] load %@ longFormVideo=%d", url, longFormVideoAirPlayEligible ? 1 : 0)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.text = trimmedTitle?.isEmpty == false
            ? trimmedTitle
            : Self.fallbackTitle(for: url)
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
            if !audioSessionActivated {
                audioSessionActivated = true
                Self.audioSessionLock.lock()
                Self.activeAudioSessionCount += 1
                Self.audioSessionLock.unlock()
            }
        } catch {
            NSLog("[RigelPlayer] audio session setup failed: %@", error.localizedDescription)
        }

        disposed = false
        notifiedPlaying = false
        customPlaybackControls = Self.isHLSURL(url)
        bottomBar.isHidden = !customPlaybackControls
        progressSlider.isHidden = true
        progressSlider.value = 0
        elapsedLabel.text = "00:00"
        durationLabel.text = "—"
        audioGroup = nil
        subtitleGroup = nil
        trackGroupsLoadedFor = nil
        tracksButton.accessibilityValue = "Loading tracks"
        showControls()

        let item = AVPlayerItem(url: avURL)
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p

        let vc = AVPlayerViewController()
        vc.player = p
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = !customPlaybackControls
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
    @objc private func playPauseTapped() {
        showControls()
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        updatePlaybackControls()
    }

    @objc private func skipBackwardTapped() {
        seek(by: -15)
    }

    @objc private func skipForwardTapped() {
        seek(by: 15)
    }

    private func seek(by offset: Double) {
        showControls()
        guard let player else { return }
        let current = player.currentTime().seconds
        let start = current.isFinite ? max(0, current) : 0
        let duration = player.currentItem?.duration.seconds ?? .nan
        let target = duration.isFinite && duration > 0
            ? min(max(0, start + offset), duration)
            : max(0, start + offset)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        updatePlaybackControls()
    }

    @objc private func progressChanged() {
        showControls()
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let target = Double(progressSlider.value) * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func updatePlaybackControls() {
        guard customPlaybackControls, let player, let item = player.currentItem else { return }
        let elapsed = player.currentTime().seconds
        elapsedLabel.text = Self.formatTime(elapsed)
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            progressSlider.isHidden = false
            progressSlider.value = Float(min(max(elapsed / duration, 0), 1))
            durationLabel.text = Self.formatTime(duration)
        } else {
            progressSlider.isHidden = true
            durationLabel.text = "—"
        }
        let imageName = player.timeControlStatus == .playing ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: imageName), for: .normal)
        playPauseButton.accessibilityLabel = player.timeControlStatus == .playing ? "Pause" : "Play"
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
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
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        controlsVisible = true
        topBar.isHidden = false
        customPlaybackControls = false
        bottomBar.isHidden = true
        audioGroup = nil
        subtitleGroup = nil
        trackGroupsLoadedFor = nil
        tracksButton.accessibilityValue = nil
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
        if trackGroupsLoadedFor !== item {
            loadTrackGroups(for: item)
        }
        updatePlaybackControls()
        if player.timeControlStatus == .playing {
            if controlsVisible, controlsHideTimer == nil {
                scheduleControlsHide()
            }
        } else if !controlsVisible {
            showControls()
        } else {
            controlsHideTimer?.invalidate()
            controlsHideTimer = nil
        }
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
