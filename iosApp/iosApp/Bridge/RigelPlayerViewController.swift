import Foundation
import AVFoundation
import AVKit
import UIKit
import SwiftUI
import ComposeApp

private final class PlayerGradientView: UIView {
    private let gradientLayer = CAGradientLayer()

    init(colors: [UIColor]) {
        super.init(frame: .zero)
        gradientLayer.colors = colors.map(\.cgColor)
        layer.addSublayer(gradientLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// AVPlayer host with native title, route, audio/subtitle, and transport controls.
/// The overlay chrome follows normal player behavior: it appears on interaction
/// and fades while playback runs. HLS proxy playlists use Rigel's own
/// transport bar because an in-progress VOD playlist is reported by AVPlayer
/// as live; its probe duration supplies the full timeline until ENDLIST appears,
/// and seeks past generated segments buffer until the exporter catches up.
/// Direct VOD media keeps AVPlayer's controls. AirPlay video handoff and PiP
/// come from AVPlayerViewController.
/// Events fire on the main thread.
final class RigelPlayerViewController: UIViewController {
    private let events: PlayerEvents
    /// Assigned by the SwiftUI host so the native control can present the
    /// app-level destination picker without expanding the Kotlin event contract.
    var onDevicesRequested: (() -> Void)?
    /// Called with an absolute media position for remote seek forwarding or
    /// proxy session restart.
    var onSeekRequested: ((Double) -> Void)?
    /// Called when a subtitle selected from OpenSubtitles is ready to retain
    /// in Kotlin playback state.
    var onSubtitleDownloaded: ((SubtitleTrack) -> Void)?

    private var player: AVPlayer?
    /// Raw URL of the item currently installed in AVPlayer. Delayed failures
    /// from a replaced proxy item must not be attributed to the new item.
    private(set) var loadedURL: String?
    private var playerVC: AVPlayerViewController?
    private var timeJumpObserver: NSObjectProtocol?
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

    private let topGradient = PlayerGradientView(
        colors: [UIColor.black.withAlphaComponent(0.72), .clear]
    )
    private let bottomGradient = PlayerGradientView(
        colors: [.clear, UIColor.black.withAlphaComponent(0.72)]
    )
    private let topBar = UIView()
    private let titleLabel = UILabel()
    private let senderLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let devicesButton = UIButton(type: .system)
    private let tracksButton = UIButton(type: .system)
    private let trackButtonsStack = UIStackView()
    private let bottomBar = UIView()
    private let progressSlider = UISlider()
    private let skipBackwardButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let elapsedLabel = UILabel()
    private let durationLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var trackGroupsLoadedFor: AVPlayerItem?
    private struct SidecarSubtitle {
        let name: String
        let language: String?
        let cues: [SubtitleParser.Cue]
    }
    private var sidecarSubtitles: [SidecarSubtitle] = []
    private var activeSidecarSubtitleIndex: Int?
    private var sidecarGeneration = 0
    private var isScrubbing = false
    private var knownDurationSeconds: Double?
    private var loadedTitle: String?
    private var startOffsetSeconds: Double = 0
    private var isProxyPlayback = false
    private var pendingScrubValue: Float?
    private var scrubGeneration = 0

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
        setupOverlayGradients()
        setupTopBar()
        setupBottomBar()
        // Sidecar subtitles are an in-app overlay and are not captured by
        // AVPlayerViewController's PiP or AirPlay handoff.
        subtitleLabel.font = .preferredFont(forTextStyle: .title3)
        subtitleLabel.textColor = .white
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.layer.shadowColor = UIColor.black.cgColor
        subtitleLabel.layer.shadowRadius = 3
        subtitleLabel.layer.shadowOpacity = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isHidden = true
        view.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -100),
        ])
        setupControlsGesture()
    }

    private func setupOverlayGradients() {
        for gradient in [topGradient, bottomGradient] {
            gradient.translatesAutoresizingMaskIntoConstraints = false
            gradient.isUserInteractionEnabled = false
            view.addSubview(gradient)
        }
        bottomGradient.alpha = 0
        NSLayoutConstraint.activate([
            topGradient.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topGradient.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topGradient.topAnchor.constraint(equalTo: view.topAnchor),
            topGradient.heightAnchor.constraint(equalToConstant: 180),

            bottomGradient.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomGradient.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomGradient.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomGradient.heightAnchor.constraint(equalToConstant: 240),
        ])
    }

    /// Controls use their own hit rectangles; there is no enclosing chrome.
    private static func controlConfiguration(symbolName: String, pointSize: CGFloat) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .white
        configuration.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        )
        configuration.contentInsets = .zero
        return configuration
    }
    private func setupTopBar() {
        topBar.backgroundColor = .clear
        topBar.isOpaque = false
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.accessibilityIdentifier = "player.topBar"
        topBar.layoutMargins = UIEdgeInsets(top: 6, left: 20, bottom: 10, right: 20)
        view.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        backButton.configuration = Self.controlConfiguration(symbolName: "xmark", pointSize: 15)
        backButton.accessibilityLabel = "Close player"
        backButton.accessibilityHint = "Return to Rigel"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(backButton)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleLabel)

        senderLabel.font = .preferredFont(forTextStyle: .subheadline)
        senderLabel.adjustsFontForContentSizeCategory = true
        senderLabel.textColor = .white.withAlphaComponent(0.7)
        senderLabel.lineBreakMode = .byTruncatingTail
        senderLabel.numberOfLines = 1
        senderLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(senderLabel)

        audioButton.configuration = Self.controlConfiguration(symbolName: "waveform", pointSize: 17)
        audioButton.accessibilityLabel = "Audio track"
        audioButton.accessibilityHint = "Choose an audio track"
        audioButton.addTarget(self, action: #selector(audioTapped), for: .touchUpInside)
        audioButton.translatesAutoresizingMaskIntoConstraints = false

        tracksButton.configuration = Self.controlConfiguration(symbolName: "captions.bubble", pointSize: 17)
        tracksButton.accessibilityLabel = "Subtitles"
        tracksButton.accessibilityHint = "Choose a subtitle track"
        tracksButton.addTarget(self, action: #selector(subtitlesTapped), for: .touchUpInside)
        tracksButton.translatesAutoresizingMaskIntoConstraints = false

        devicesButton.configuration = Self.controlConfiguration(symbolName: "airplayvideo", pointSize: 17)
        devicesButton.accessibilityLabel = "Playback destinations"
        devicesButton.accessibilityHint = "Choose AirPlay or a network device"
        devicesButton.addTarget(self, action: #selector(devicesTapped), for: .touchUpInside)
        devicesButton.translatesAutoresizingMaskIntoConstraints = false

        trackButtonsStack.axis = .horizontal
        trackButtonsStack.alignment = .center
        trackButtonsStack.spacing = 4
        trackButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        trackButtonsStack.addArrangedSubview(audioButton)
        trackButtonsStack.addArrangedSubview(tracksButton)
        trackButtonsStack.addArrangedSubview(devicesButton)
        topBar.addSubview(trackButtonsStack)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.leadingAnchor),
            backButton.topAnchor.constraint(equalTo: topBar.layoutMarginsGuide.topAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),

            trackButtonsStack.trailingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.trailingAnchor),
            trackButtonsStack.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            trackButtonsStack.heightAnchor.constraint(equalToConstant: 44),

            audioButton.widthAnchor.constraint(equalToConstant: 44),
            audioButton.heightAnchor.constraint(equalToConstant: 44),
            tracksButton.widthAnchor.constraint(equalToConstant: 44),
            tracksButton.heightAnchor.constraint(equalToConstant: 44),
            devicesButton.widthAnchor.constraint(equalToConstant: 44),
            devicesButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trackButtonsStack.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: backButton.topAnchor, constant: 2),

            senderLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            senderLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            senderLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            senderLabel.bottomAnchor.constraint(lessThanOrEqualTo: backButton.bottomAnchor),

            topBar.bottomAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 12),
        ])
    }

    private func setupBottomBar() {
        bottomBar.backgroundColor = .clear
        bottomBar.isOpaque = false
        bottomBar.accessibilityIdentifier = "player.bottomBar"
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.isHidden = true
        bottomBar.layoutMargins = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view.addSubview(bottomBar)

        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.minimumTrackTintColor = .white
        progressSlider.maximumTrackTintColor = .white.withAlphaComponent(0.35)
        progressSlider.addTarget(self, action: #selector(progressChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(progressTouchDown), for: .touchDown)
        progressSlider.addTarget(
            self,
            action: #selector(progressTouchUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        progressSlider.accessibilityIdentifier = "player.progressSlider"
        progressSlider.accessibilityLabel = "Playback position"
        progressSlider.accessibilityHint = "Adjust playback position"
        progressSlider.translatesAutoresizingMaskIntoConstraints = false

        for label in [elapsedLabel, durationLabel] {
            let preferredSize = UIFont.preferredFont(forTextStyle: .caption1).pointSize
            label.font = UIFont.monospacedDigitSystemFont(ofSize: preferredSize, weight: .medium)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .white
            label.text = "00:00"
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        durationLabel.textAlignment = .right

        let timeline = UIStackView(arrangedSubviews: [elapsedLabel, progressSlider, durationLabel])
        timeline.axis = .horizontal
        timeline.alignment = .center
        timeline.spacing = 10
        timeline.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(timeline)

        let buttons: [(UIButton, String, String, Selector)] = [
            (skipBackwardButton, "gobackward.15", "Back 15 seconds", #selector(skipBackwardTapped)),
            (playPauseButton, "play.fill", "Play", #selector(playPauseTapped)),
            (skipForwardButton, "goforward.15", "Forward 15 seconds", #selector(skipForwardTapped)),
        ]
        for (button, imageName, label, action) in buttons {
            button.configuration = Self.controlConfiguration(symbolName: imageName, pointSize: 22)
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            if button !== playPauseButton {
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            }
        }

        var playConfiguration = UIButton.Configuration.plain()
        playConfiguration.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        )
        playConfiguration.baseForegroundColor = .white
        playConfiguration.contentInsets = .zero
        playPauseButton.configuration = playConfiguration
        playPauseButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 64).isActive = true
        playPauseButton.accessibilityHint = "Pause or resume playback"

        let transportControls = UIStackView(arrangedSubviews: [
            skipBackwardButton,
            playPauseButton,
            skipForwardButton,
        ])
        transportControls.axis = .horizontal
        transportControls.alignment = .center
        transportControls.spacing = 28
        transportControls.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(transportControls)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            timeline.leadingAnchor.constraint(equalTo: bottomBar.layoutMarginsGuide.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: bottomBar.layoutMarginsGuide.trailingAnchor),
            timeline.topAnchor.constraint(equalTo: bottomBar.layoutMarginsGuide.topAnchor),
            progressSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            transportControls.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            transportControls.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 2),
            transportControls.bottomAnchor.constraint(equalTo: bottomBar.layoutMarginsGuide.bottomAnchor),
            bottomBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 116),
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
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.topBar.alpha = 1
            self.bottomBar.alpha = 1
            self.topGradient.alpha = 1
            self.bottomGradient.alpha = self.customPlaybackControls ? 1 : 0
        }
        scheduleControlsHide()
    }

    func hideControls() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        controlsVisible = false
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.topBar.alpha = 0
                self.bottomBar.alpha = 0
                self.topGradient.alpha = 0
                self.bottomGradient.alpha = 0
            },
            completion: { _ in
                if !self.controlsVisible {
                    self.topBar.isHidden = true
                    if self.customPlaybackControls {
                        self.bottomBar.isHidden = true
                    }
                }
            }
        )
    }

    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        guard controlsVisible, !isScrubbing, player?.timeControlStatus == .playing else { return }
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    @objc private func backTapped() {
        events.onBack()
    }
    @objc private func devicesTapped() {
        showControls()
        onDevicesRequested?()
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

    @objc private func audioTapped() {
        showControls()
        guard let group = audioGroup, !group.options.isEmpty else {
            presentTrackPicker(
                title: "Audio",
                options: [],
                emptyMessage: trackGroupsLoadedFor == nil
                    ? "Audio tracks are still loading."
                    : "No alternate audio tracks are available."
            )
            return
        }
        let selected = player?.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
        let options = group.options.enumerated().map { index, option in
            TrackPickerOption(
                id: "audio-\(index)",
                title: option.displayName,
                isSelected: selected === option,
                select: { [weak self] in
                    guard let self,
                          let currentGroup = self.audioGroup,
                          currentGroup.options.indices.contains(index) else { return }
                    self.selectMediaOption(currentGroup.options[index], in: currentGroup)
                    self.updateTrackButtons()
                }
            )
        }
        presentTrackPicker(
            title: "Audio",
            options: options,
            emptyMessage: "No alternate audio tracks are available."
        )
    }

    @objc private func subtitlesTapped() {
        showControls()
        var options: [TrackPickerOption] = []
        if let group = subtitleGroup, !group.options.isEmpty {
            let selectedNative = player?.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
            if group.allowsEmptySelection && sidecarSubtitles.isEmpty {
                options.append(
                    TrackPickerOption(
                        id: "subtitles-off",
                        title: "Off",
                        isSelected: selectedNative == nil,
                        select: { [weak self] in
                            guard let self else { return }
                            self.activeSidecarSubtitleIndex = nil
                            self.selectMediaOption(nil, in: group)
                            self.updateSidecarSubtitle()
                            self.updateTrackButtons()
                        }
                    )
                )
            }
            for (index, option) in group.options.enumerated() {
                options.append(
                    TrackPickerOption(
                        id: "subtitle-\(index)",
                        title: option.displayName,
                        isSelected: activeSidecarSubtitleIndex == nil && selectedNative === option,
                        select: { [weak self] in
                            guard let self,
                                  let currentGroup = self.subtitleGroup,
                                  currentGroup.options.indices.contains(index) else { return }
                            self.activeSidecarSubtitleIndex = nil
                            self.selectMediaOption(currentGroup.options[index], in: currentGroup)
                            self.updateSidecarSubtitle()
                            self.updateTrackButtons()
                        }
                    )
                )
            }
        }
        if !sidecarSubtitles.isEmpty {
            let nativeSelected = subtitleGroup.flatMap {
                player?.currentItem?.currentMediaSelection.selectedMediaOption(in: $0)
            } != nil
            options.append(
                TrackPickerOption(
                    id: "sidecar-off",
                    title: "Off",
                    isSelected: activeSidecarSubtitleIndex == nil && !nativeSelected,
                    select: { [weak self] in
                        guard let self else { return }
                        self.activeSidecarSubtitleIndex = nil
                        if let group = self.subtitleGroup {
                            self.selectMediaOption(nil, in: group)
                        }
                        self.updateSidecarSubtitle()
                        self.updateTrackButtons()
                    }
                )
            )
            for (index, sidecar) in sidecarSubtitles.enumerated() {
                let label = sidecar.language ?? sidecar.name
                options.append(
                    TrackPickerOption(
                        id: "sidecar-\(index)",
                        title: label,
                        isSelected: activeSidecarSubtitleIndex == index,
                        select: { [weak self] in
                            guard let self, self.sidecarSubtitles.indices.contains(index) else { return }
                            self.activeSidecarSubtitleIndex = index
                            if let group = self.subtitleGroup {
                                self.selectMediaOption(nil, in: group)
                            }
                            self.updateSidecarSubtitle()
                            self.updateTrackButtons()
                        }
                    )
                )
            }
        }
        presentTrackPicker(
            title: "Subtitles",
            options: options,
            emptyMessage: trackGroupsLoadedFor == nil
                ? "Subtitle tracks are still loading."
                : "No subtitle tracks are available.",
            moreAction: { [weak self] in
                self?.presentOpenSubtitlesSearch()
            }
        )
    }

    /// Native track pickers own the selection after a user makes a choice.
    /// AVPlayer's automatic language/accessibility criteria can otherwise
    /// replace a manually selected legible option during HLS playback.
    private func selectMediaOption(
        _ option: AVMediaSelectionOption?,
        in group: AVMediaSelectionGroup
    ) {
        guard let player, let item = player.currentItem else { return }
        player.appliesMediaSelectionCriteriaAutomatically = false
        item.select(option, in: group)
    }

    private func presentTrackPicker(
        title: String,
        options: [TrackPickerOption],
        emptyMessage: String,
        moreAction: (() -> Void)? = nil
    ) {
        let picker = UIHostingController(
            rootView: TrackPickerSheet(
                title: title,
                options: options,
                emptyMessage: emptyMessage,
                moreAction: moreAction
            )
        )
        picker.modalPresentationStyle = .pageSheet
        picker.view.backgroundColor = .systemBackground
        if let sheet = picker.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(picker, animated: true)
    }

    private func presentOpenSubtitlesSearch() {
        guard !disposed else { return }
        let fallbackQuery = Self.fallbackTitle(for: loadedURL ?? "")
        let query: String
        if let loadedTitle {
            let trimmed = loadedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            query = trimmed.isEmpty ? fallbackQuery : trimmed
        } else {
            query = fallbackQuery
        }
        let sheet = UIHostingController(
            rootView: OpenSubtitlesSearchSheet(
                query: query,
                client: OpenSubtitlesClient.shared,
                onDownloaded: { [weak self] track in
                    guard let self, !self.disposed else { return }
                    self.loadSidecarSubtitles([track]) { [weak self] index in
                        guard let self else { return }
                        self.activeSidecarSubtitleIndex = index
                        if let group = self.subtitleGroup {
                            self.selectMediaOption(nil, in: group)
                        }
                        self.updateSidecarSubtitle()
                        self.updateTrackButtons()
                    }
                    self.onSubtitleDownloaded?(track)
                }
            )
        )
        sheet.modalPresentationStyle = UIModalPresentationStyle.pageSheet
        sheet.view.backgroundColor = UIColor.systemBackground
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [
                UISheetPresentationController.Detent.medium(),
                UISheetPresentationController.Detent.large(),
            ]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
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
                self.updateTrackButtons()
            }
        }
    }

    private func updateTrackButtons() {
        let audioCount = audioGroup?.options.count ?? 0
        let subtitleCount = (subtitleGroup?.options.count ?? 0) + sidecarSubtitles.count
        audioButton.accessibilityValue = audioCount == 0
            ? "No alternate audio tracks"
            : "\(audioCount) audio track" + (audioCount == 1 ? "" : "s")
        tracksButton.accessibilityValue = subtitleCount == 0
            ? "No subtitle tracks"
            : "\(subtitleCount) subtitle track" + (subtitleCount == 1 ? "" : "s")
    }
    private func loadSidecarSubtitles(
        _ tracks: [SubtitleTrack],
        onLoaded: @escaping (Int) -> Void = { _ in }
    ) {
        let limitedTracks = Array(tracks.prefix(16))
        if tracks.count > limitedTracks.count {
            NSLog("[RigelPlayer] ignoring %ld sidecar subtitle URLs over the limit", tracks.count - limitedTracks.count)
        }
        let generation = sidecarGeneration
        for (index, track) in limitedTracks.enumerated() {
            let rawURL = track.url
            guard let url = URL(string: rawURL) else {
                NSLog("[RigelPlayer] sidecar %@ failed: invalid URL", rawURL)
                continue
            }
            let extensionName = url.pathExtension.lowercased()
            if extensionName == "ass" {
                NSLog("[RigelPlayer] sidecar %@ skipped: ASS is unsupported", rawURL)
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data else {
                    let detail = error?.localizedDescription ?? "HTTP request failed"
                    NSLog("[RigelPlayer] sidecar %@ failed: %@", rawURL, detail)
                    return
                }
                guard let text = SubtitleParser.decode(
                    data: data,
                    encodingName: http.textEncodingName
                ) else {
                    NSLog("[RigelPlayer] sidecar %@ failed: unsupported text encoding", rawURL)
                    return
                }
                var cues = extensionName == "vtt"
                    ? SubtitleParser.parseVTT(text)
                    : SubtitleParser.parseSRT(text)
                cues.sort { $0.start < $1.start }
                guard !cues.isEmpty else {
                    NSLog("[RigelPlayer] sidecar %@ failed: no valid cues", rawURL)
                    return
                }
                let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = title?.isEmpty == false
                    ? title!
                    : Self.sidecarName(for: url, fallback: "Subtitles \(index + 1)")
                let language = track.language?.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard self.sidecarGeneration == generation, !self.disposed else { return }
                    let sidecarIndex = self.sidecarSubtitles.count
                    self.sidecarSubtitles.append(
                        SidecarSubtitle(
                            name: name,
                            language: language?.isEmpty == false ? language : nil,
                            cues: cues,
                        )
                    )
                    onLoaded(sidecarIndex)
                    self.updateTrackButtons()
                    NSLog("[RigelPlayer] sidecar %@ ok", rawURL)
                }
            }.resume()
        }
    }

    private static func sidecarName(for url: URL, fallback: String) -> String {
        let decoded = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func updateSidecarSubtitle() {
        guard let index = activeSidecarSubtitleIndex,
              sidecarSubtitles.indices.contains(index) else {
            subtitleLabel.text = nil
            subtitleLabel.isHidden = true
            return
        }
        let seconds = mediaSeconds
        guard seconds.isFinite else {
            subtitleLabel.text = nil
            subtitleLabel.isHidden = true
            return
        }
        let cue = sidecarSubtitles[index].cues.first {
            $0.start <= seconds && seconds < $0.end
        }
        subtitleLabel.text = cue?.text
        subtitleLabel.isHidden = cue == nil
    }

    func load(
        url: String,
        title: String?,
        sender: String?,
        longFormVideoAirPlayEligible: Bool,
        subtitleTracks: [SubtitleTrack] = [],
        durationSeconds: Double? = nil,
        isProxy: Bool = false,
        startOffsetSeconds: Double = 0
    ) {
        NSLog("[RigelPlayer] load %@ longFormVideo=%d", url, longFormVideoAirPlayEligible ? 1 : 0)
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle?.isEmpty == false
            ? trimmedTitle!
            : Self.fallbackTitle(for: url)
        titleLabel.text = resolvedTitle
        let trimmedSender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        senderLabel.text = trimmedSender.map { "via \($0)" }
        senderLabel.isHidden = trimmedSender?.isEmpty != false
        guard let avURL = URL(string: url) else {
            events.onError(message: "invalid URL: \(url)")
            return
        }
        tearDownPlayer()
        loadedURL = url
        loadedTitle = resolvedTitle
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
        isScrubbing = false
        knownDurationSeconds = durationSeconds
        self.startOffsetSeconds = max(0, startOffsetSeconds.isFinite ? startOffsetSeconds : 0)
        isProxyPlayback = isProxy
        pendingScrubValue = nil
        customPlaybackControls = Self.isHLSURL(url)
        bottomBar.isHidden = !customPlaybackControls
        progressSlider.isHidden = true
        progressSlider.value = 0
        elapsedLabel.text = "00:00"
        durationLabel.text = "—"
        audioGroup = nil
        subtitleGroup = nil
        trackGroupsLoadedFor = nil
        audioButton.isHidden = false
        tracksButton.isHidden = false
        audioButton.accessibilityValue = "Loading audio tracks"
        tracksButton.accessibilityValue = "Loading subtitle tracks"
        showControls()

        let item = AVPlayerItem(url: avURL)
        let p = AVPlayer(playerItem: item)
        p.allowsExternalPlayback = true
        player = p
        if !customPlaybackControls {
            timeJumpObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.AVPlayerItemTimeJumped,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.disposed else { return }
                self.onSeekRequested?(self.mediaSeconds)
            }
        }
        if !isProxyPlayback {
            loadSidecarSubtitles(subtitleTracks)
        }

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
        updatePlaybackControls()
    }
    /// Proxy output keeps the full probed VOD duration while its HLS playlist
    /// grows; direct HLS uses AVPlayer's native duration behavior.
    private func effectiveDuration(_ item: AVPlayerItem) -> Double {
        if isProxyPlayback,
           let knownDurationSeconds,
           knownDurationSeconds.isFinite,
           knownDurationSeconds > 0 {
            return knownDurationSeconds
        }
        let reported = item.duration.seconds
        return reported.isFinite && reported > 0 ? reported : .nan
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


    private var mediaSeconds: Double {
        let current = player?.currentTime().seconds ?? 0
        guard current.isFinite else { return startOffsetSeconds }
        return max(0, startOffsetSeconds + current)
    }

    private func performSeek(absoluteTarget: Double) {
        showControls()
        pendingScrubValue = nil
        scrubGeneration &+= 1
        guard let player, let item = player.currentItem, item.status != .failed else { return }
        let duration = effectiveDuration(item)
        guard duration.isFinite, duration > 0 else { return }
        let target = min(max(absoluteTarget, 0), duration)
        if isProxyPlayback {
            onSeekRequested?(target)
            return
        }
        let generation = scrubGeneration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self, weak player] finished in
            DispatchQueue.main.async {
                guard let self, let player, self.player === player, self.scrubGeneration == generation else { return }
                if finished {
                    self.updatePlaybackControls()
                    self.scheduleControlsHide()
                } else {
                    self.updatePlaybackControls()
                }
            }
        }
        onSeekRequested?(target)
    }

    @objc private func skipBackwardTapped() {
        performSeek(absoluteTarget: mediaSeconds - 15)
    }

    @objc private func skipForwardTapped() {
        performSeek(absoluteTarget: mediaSeconds + 15)
    }

    @objc private func progressTouchDown() {
        scrubGeneration &+= 1
        isScrubbing = true
        pendingScrubValue = progressSlider.value
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
        showControls()
    }

    @objc private func progressChanged() {
        guard isScrubbing else { return }
        pendingScrubValue = progressSlider.value
        showControls()
    }

    @objc private func progressTouchUp() {
        isScrubbing = false
        pendingScrubValue = pendingScrubValue ?? progressSlider.value
        guard let item = player?.currentItem else {
            pendingScrubValue = nil
            showControls()
            return
        }
        let duration = effectiveDuration(item)
        guard duration.isFinite, duration > 0 else {
            pendingScrubValue = nil
            showControls()
            return
        }
        let target = Double(pendingScrubValue ?? progressSlider.value) * duration
        performSeek(absoluteTarget: target)
        showControls()
    }
    private func updatePlaybackControls() {
        guard customPlaybackControls, let player, let item = player.currentItem else { return }
        let elapsed = mediaSeconds
        let elapsedText = Self.formatTime(elapsed)
        elapsedLabel.text = elapsedText
        let duration = effectiveDuration(item)
        if duration.isFinite, duration > 0 {
            progressSlider.isHidden = false
            if let pendingScrubValue {
                progressSlider.value = pendingScrubValue
            } else if !isScrubbing {
                progressSlider.value = Float(min(max(elapsed / duration, 0), 1))
            }
            let durationText = Self.formatTime(duration)
            durationLabel.text = durationText
            progressSlider.accessibilityValue = "\(elapsedText) of \(durationText)"
        } else {
            progressSlider.isHidden = true
            durationLabel.text = "—"
            progressSlider.accessibilityValue = elapsedText
        }
        let isPlaying = player.timeControlStatus == .playing
        var configuration = playPauseButton.configuration
        configuration?.image = UIImage(
            systemName: isPlaying ? "pause.fill" : "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        )
        playPauseButton.configuration = configuration
        playPauseButton.accessibilityLabel = isPlaying ? "Pause" : "Play"
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
        loadedURL = nil
        loadedTitle = nil
        controlsHideTimer?.invalidate()
        if let observer = timeJumpObserver {
            NotificationCenter.default.removeObserver(observer)
            timeJumpObserver = nil
        }
        controlsHideTimer = nil
        controlsVisible = true
        topBar.isHidden = false
        topBar.alpha = 1
        bottomBar.alpha = 1
        topGradient.alpha = 1
        bottomGradient.alpha = 0
        customPlaybackControls = false
        isScrubbing = false
        knownDurationSeconds = nil
        startOffsetSeconds = 0
        isProxyPlayback = false
        pendingScrubValue = nil
        scrubGeneration &+= 1
        bottomBar.isHidden = true
        audioGroup = nil
        subtitleGroup = nil
        trackGroupsLoadedFor = nil
        sidecarGeneration &+= 1
        sidecarSubtitles.removeAll()
        activeSidecarSubtitleIndex = nil
        subtitleLabel.text = nil
        subtitleLabel.isHidden = true
        audioButton.accessibilityValue = nil
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
        updateSidecarSubtitle()
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
private struct TrackPickerOption: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let select: () -> Void
}

private struct TrackPickerSheet: View {
    let title: String
    let options: [TrackPickerOption]
    let emptyMessage: String
    let moreAction: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if options.isEmpty {
                    VStack {
                        Spacer()
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        if let moreAction {
                            Button("Get More from OpenSubtitles") {
                                dismiss()
                                DispatchQueue.main.async { moreAction() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(options) { option in
                            Button {
                                option.select()
                                dismiss()
                            } label: {
                                HStack {
                                    Text(option.title)
                                    Spacer()
                                    if option.isSelected {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(option.isSelected ? "Selected" : "")
                        }
                        if let moreAction {
                            Section {
                                Button("Get More from OpenSubtitles") {
                                    dismiss()
                                    DispatchQueue.main.async { moreAction() }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
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
        longFormVideoAirPlayEligible: Bool,
        subtitleTracks: [SubtitleTrack],
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
