import Foundation
import AVFoundation
import AVKit
import UIKit
import SwiftUI
import ComposeApp
import Combine

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

private final class SubtitleInsetLabel: UILabel {
    var textInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
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
    /// Called when the active subtitle selection changes. A non-nil track is
    /// rebuilt through the Kotlin-owned proxy so an AirPlay receiver can fetch it.
    var onExternalSubtitleSelected: ((SubtitleTrack?, Double) -> Void)?

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
    private let subtitleLabel = SubtitleInsetLabel()
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var trackGroupsLoadedFor: AVPlayerItem?
    private struct SidecarSubtitle {
        let order: Int
        let track: SubtitleTrack
        let name: String
        let language: String?
        let cues: [SubtitleParser.Cue]
    }
    private var sidecarSubtitles: [SidecarSubtitle] = []
    private var activeSidecarSubtitleIndex: Int?
    private var sidecarGeneration = 0
    private var nextSidecarOrder = 0
    private var subtitleBottomConstraint: NSLayoutConstraint?
    private var isScrubbing = false
    private var knownDurationSeconds: Double?
    private var loadedTitle: String?
    private var startOffsetSeconds: Double = 0
    private var isProxyPlayback = false
    private var selectedExternalSubtitleUrl: String?
    private var selectedExternalSubtitleOption: AVMediaSelectionOption?
    private var proxyExternalSubtitleUrl: String?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var pendingScrubValue: Float?
    private var scrubGeneration = 0
    private var subtitleCustomizationModel: SubtitleCustomizationModel?
    private var subtitleCustomizationHost: UIViewController?
    private var appliedSubtitleAppearance: SubtitleAppearance?
    private var renderedSubtitleText: String?
    private var renderedSubtitleAppearance: SubtitleAppearance?
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
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.accessibilityIdentifier = "player.subtitleLabel"
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isHidden = true
        applySubtitleAppearance(SubtitlePreferences.appearance)
        view.addSubview(subtitleLabel)
        let bottomConstraint = subtitleLabel.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -SubtitlePreferences.appearance.bottomInset
        )
        subtitleBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomConstraint,
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
    private static let selectedSubtitleMarker = "RigelSelected__"

    private static func subtitleDisplayName(for option: AVMediaSelectionOption) -> String {
        let name = option.displayName
        guard name.hasPrefix(selectedSubtitleMarker) else { return name }
        return String(name.dropFirst(selectedSubtitleMarker.count))
    }

    private func selectedExternalOption(in group: AVMediaSelectionGroup?) -> AVMediaSelectionOption? {
        guard isProxyPlayback, selectedExternalSubtitleUrl != nil, let group else { return nil }
        return group.options.first {
            $0.displayName.hasPrefix(Self.selectedSubtitleMarker)
        } ?? group.options.first
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
        let nativeOptions = visibleNativeSubtitleOptions()
        let selectedNative = subtitleGroup.flatMap {
            player?.currentItem?.currentMediaSelection.selectedMediaOption(in: $0)
        }
        let canShowOff = nativeOptions.isEmpty || subtitleGroup?.allowsEmptySelection == true
        if canShowOff && (!nativeOptions.isEmpty || !sidecarSubtitles.isEmpty) {
            options.append(
                TrackPickerOption(
                    id: "subtitles-off",
                    title: "Off",
                    isSelected: activeSidecarSubtitleIndex == nil && selectedNative == nil,
                    select: { [weak self] in
                        guard let self else { return }
                        self.activeSidecarSubtitleIndex = nil
                        self.selectedExternalSubtitleUrl = nil
                        if let group = self.subtitleGroup {
                            self.selectMediaOption(nil, in: group)
                        }
                        self.updateSidecarSubtitle()
                        self.updateTrackButtons()
                        self.onExternalSubtitleSelected?(nil, self.mediaSeconds)
                    }
                )
            )
        }
        for (index, option) in nativeOptions.enumerated() {
            options.append(
                TrackPickerOption(
                    id: "subtitle-\(index)",
                    title: Self.subtitleDisplayName(for: option),
                    isSelected: activeSidecarSubtitleIndex == nil && selectedNative === option,
                    select: { [weak self] in
                        guard let self,
                              let currentGroup = self.subtitleGroup,
                              currentGroup.options.contains(where: { $0 === option }) else { return }
                        self.activeSidecarSubtitleIndex = nil
                        self.selectedExternalSubtitleUrl = nil
                        self.selectMediaOption(option, in: currentGroup)
                        self.updateSidecarSubtitle()
                        self.updateTrackButtons()
                        self.onExternalSubtitleSelected?(nil, self.mediaSeconds)
                    }
                )
            )
        }
        for (index, sidecar) in sidecarSubtitles.enumerated() {
            let order = sidecar.order
            let label = sidecar.language ?? sidecar.name
            options.append(
                TrackPickerOption(
                    id: "sidecar-\(order)",
                    title: label,
                    isSelected: activeSidecarSubtitleIndex == index,
                    select: { [weak self] in
                        guard let self,
                              let currentIndex = self.sidecarSubtitles.firstIndex(where: { $0.order == order }) else {
                            return
                        }
                        self.activeSidecarSubtitleIndex = currentIndex
                        self.selectedExternalSubtitleUrl = sidecar.track.url
                        if let group = self.subtitleGroup {
                            self.selectMediaOption(nil, in: group)
                        }
                        self.updateSidecarSubtitle()
                        self.updateTrackButtons()
                        self.onExternalSubtitleSelected?(sidecar.track, self.mediaSeconds)
                    }
                )
            )
        }
        let customizeEnabled = activeSidecarSubtitleIndex.map {
            sidecarSubtitles.indices.contains($0)
        } ?? false
        presentTrackPicker(
            title: "Subtitles",
            options: options,
            emptyMessage: trackGroupsLoadedFor == nil
                ? "Subtitle tracks are still loading."
                : "No subtitle tracks are available.",
            moreAction: { [weak self] in
                self?.presentOpenSubtitlesSearch()
            },
            customizeAction: { [weak self] in
                self?.presentSubtitleCustomization()
            },
            customizeEnabled: customizeEnabled
        )
    }

    private func presentSubtitleCustomization() {
        guard let index = activeSidecarSubtitleIndex,
              sidecarSubtitles.indices.contains(index) else {
            return
        }
        let model = SubtitleCustomizationModel(
            onChange: { [weak self] appearance, _ in
                guard let self else { return }
                self.applySubtitleAppearance(appearance)
                self.subtitleBottomConstraint?.constant = -appearance.bottomInset
                self.updateSidecarSubtitle()
            }
        )
        model.isExternalPlaybackActive = player?.isExternalPlaybackActive ?? false
        subtitleCustomizationModel = model
        let sheet = UIHostingController(
            rootView: SubtitleCustomizationSheet(model: model)
        )
        sheet.modalPresentationStyle = .pageSheet
        sheet.view.backgroundColor = .systemBackground
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        subtitleCustomizationHost = sheet
        present(sheet, animated: true)
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
        moreAction: (() -> Void)? = nil,
        customizeAction: (() -> Void)? = nil,
        customizeEnabled: Bool = true
    ) {
        let picker = UIHostingController(
            rootView: TrackPickerSheet(
                title: title,
                options: options,
                emptyMessage: emptyMessage,
                moreAction: moreAction,
                customizeAction: customizeAction,
                customizeEnabled: customizeEnabled
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
                        self.selectedExternalSubtitleUrl = track.url
                        self.activeSidecarSubtitleIndex = index
                        if let group = self.subtitleGroup {
                            self.selectMediaOption(nil, in: group)
                        }
                        self.updateSidecarSubtitle()
                        self.updateTrackButtons()
                        self.onExternalSubtitleSelected?(track, self.mediaSeconds)
                    }
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
                self.selectedExternalSubtitleOption = self.selectedExternalOption(in: subtitles)
                self.trackGroupsLoadedFor = item
                self.reconcileSubtitlePresentation(
                    externalPlaybackActive: self.player?.isExternalPlaybackActive ?? false
                )
                self.updateTrackButtons()
            }
        }
    }

    private var selectedSidecarIsLoaded: Bool {
        guard let selectedExternalSubtitleUrl else { return false }
        return sidecarSubtitles.contains { $0.track.url == selectedExternalSubtitleUrl }
    }

    private var proxySidecarIsLoaded: Bool {
        guard let proxyExternalSubtitleUrl else { return false }
        return sidecarSubtitles.contains { $0.track.url == proxyExternalSubtitleUrl }
    }

    private func visibleNativeSubtitleOptions() -> [AVMediaSelectionOption] {
        guard let subtitleGroup else { return [] }
        guard proxySidecarIsLoaded, let selectedExternalSubtitleOption else {
            return subtitleGroup.options
        }
        return subtitleGroup.options.filter { $0 !== selectedExternalSubtitleOption }
    }

    func reconcileSubtitlePresentation(externalPlaybackActive: Bool) {
        subtitleCustomizationModel?.isExternalPlaybackActive = externalPlaybackActive
        guard selectedExternalSubtitleUrl != nil,
              let subtitleGroup,
              let selectedExternalSubtitleOption else {
            if externalPlaybackActive {
                renderSubtitleText(nil)
                subtitleLabel.isHidden = true
            }
            return
        }
        if externalPlaybackActive {
            selectMediaOption(selectedExternalSubtitleOption, in: subtitleGroup)
            renderSubtitleText(nil)
            subtitleLabel.isHidden = true
        } else if selectedSidecarIsLoaded {
            selectMediaOption(nil, in: subtitleGroup)
            updateSidecarSubtitle()
        } else {
            renderSubtitleText(nil)
            subtitleLabel.isHidden = true
        }
        updateTrackButtons()
    }

    private func updateTrackButtons() {
        let audioCount = audioGroup?.options.count ?? 0
        let subtitleCount = visibleNativeSubtitleOptions().count + sidecarSubtitles.count
        audioButton.accessibilityValue = audioCount == 0
            ? "No alternate audio tracks"
            : "\(audioCount) audio track" + (audioCount == 1 ? "" : "s")
        tracksButton.accessibilityValue = subtitleCount == 0
            ? "No subtitle tracks"
            : "\(subtitleCount) subtitle track" + (subtitleCount == 1 ? "" : "s")
    }
    private func applySubtitleAppearance(_ appearance: SubtitleAppearance) {
        let weight: UIFont.Weight = appearance.bold ? .bold : .regular
        let baseFont = UIFont.systemFont(ofSize: appearance.fontSizePoints, weight: weight)
        subtitleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: baseFont)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.backgroundColor = appearance.backgroundColor.color.withAlphaComponent(
            appearance.backgroundOpacity
        )
        subtitleLabel.layer.cornerRadius = 6
        subtitleLabel.layer.masksToBounds = true
        appliedSubtitleAppearance = appearance
        renderedSubtitleAppearance = nil
        renderSubtitleText(renderedSubtitleText)
    }

    private func renderSubtitleText(_ text: String?) {
        guard let appearance = appliedSubtitleAppearance else {
            subtitleLabel.attributedText = text.map { NSAttributedString(string: $0) }
            renderedSubtitleText = text
            renderedSubtitleAppearance = nil
            return
        }
        guard renderedSubtitleText != text || renderedSubtitleAppearance != appearance else {
            return
        }
        renderedSubtitleText = text
        renderedSubtitleAppearance = appearance
        guard let text else {
            subtitleLabel.attributedText = nil
            return
        }
        let foreground = appearance.textColor.color.withAlphaComponent(appearance.textOpacity)
        let outline = appearance.outlineEnabled ? appearance.outlineColor.color : .clear
        subtitleLabel.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: subtitleLabel.font as Any,
                .foregroundColor: foreground,
                .strokeColor: outline,
                .strokeWidth: appearance.outlineEnabled ? -3 : 0,
            ]
        )
    }

    func installLoadedSidecar(
        track: SubtitleTrack,
        order: Int,
        cues: [SubtitleParser.Cue],
        onLoaded: @escaping (Int) -> Void = { _ in }
    ) {
        guard !cues.isEmpty, let url = URL(string: track.url) else { return }
        let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title?.isEmpty == false
            ? title!
            : Self.sidecarName(for: url, fallback: "Subtitles \(order + 1)")
        let language = track.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeOrder = activeSidecarSubtitleIndex.flatMap { index in
            sidecarSubtitles.indices.contains(index)
                ? sidecarSubtitles[index].order
                : nil
        }
        sidecarSubtitles.append(
            SidecarSubtitle(
                order: order,
                track: track,
                name: name,
                language: language?.isEmpty == false ? language : nil,
                cues: cues
            )
        )
        sidecarSubtitles.sort { $0.order < $1.order }
        guard let sidecarIndex = sidecarSubtitles.firstIndex(where: { $0.order == order }) else {
            return
        }
        if selectedExternalSubtitleUrl == track.url {
            activeSidecarSubtitleIndex = sidecarIndex
        } else if let activeOrder {
            activeSidecarSubtitleIndex = sidecarSubtitles.firstIndex {
                $0.order == activeOrder
            }
        }
        onLoaded(sidecarIndex)
        updateTrackButtons()
        updateSidecarSubtitle()
        reconcileSubtitlePresentation(
            externalPlaybackActive: player?.isExternalPlaybackActive ?? false
        )
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
        for track in limitedTracks {
            let sidecarOrder = nextSidecarOrder
            nextSidecarOrder += 1
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
                DispatchQueue.main.async {
                    guard self.sidecarGeneration == generation, !self.disposed else { return }
                    self.installLoadedSidecar(
                        track: track,
                        order: sidecarOrder,
                        cues: cues,
                        onLoaded: onLoaded
                    )
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
        if player?.isExternalPlaybackActive == true {
            renderSubtitleText(nil)
            subtitleLabel.isHidden = true
            return
        }
        guard let index = activeSidecarSubtitleIndex,
              sidecarSubtitles.indices.contains(index) else {
            renderSubtitleText(nil)
            subtitleLabel.isHidden = true
            return
        }
        let appearance = SubtitlePreferences.appearance
        if appliedSubtitleAppearance != appearance {
            applySubtitleAppearance(appearance)
        }
        subtitleBottomConstraint?.constant = -appearance.bottomInset
        let seconds = mediaSeconds - SubtitlePreferences.delay
        guard seconds.isFinite else {
            renderSubtitleText(nil)
            subtitleLabel.isHidden = true
            return
        }
        let cue = sidecarSubtitles[index].cues.first {
            $0.start <= seconds && seconds < $0.end
        }
        renderSubtitleText(cue?.text)
        subtitleLabel.isHidden = cue == nil
    }

    func load(
        url: String,
        title: String?,
        sender: String?,
        longFormVideoAirPlayEligible: Bool,
        subtitleTracks: [SubtitleTrack] = [],
        selectedExternalSubtitleUrl: String? = nil,
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
        self.selectedExternalSubtitleUrl = selectedExternalSubtitleUrl
        proxyExternalSubtitleUrl = isProxy ? selectedExternalSubtitleUrl : nil
        applySubtitleAppearance(SubtitlePreferences.appearance)
        customPlaybackControls = Self.isHLSURL(url)
        pendingScrubValue = nil
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
        externalPlaybackObservation = p.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self, weak p] observedPlayer, _ in
            let active = observedPlayer.isExternalPlaybackActive
            DispatchQueue.main.async {
                guard let self,
                      let p,
                      self.player === p,
                      !self.disposed else { return }
                self.reconcileSubtitlePresentation(externalPlaybackActive: active)
            }
        }
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
        if !subtitleTracks.isEmpty {
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
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        subtitleCustomizationHost?.dismiss(animated: false)
        subtitleCustomizationHost = nil
        subtitleCustomizationModel = nil
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
        selectedExternalSubtitleUrl = nil
        selectedExternalSubtitleOption = nil
        proxyExternalSubtitleUrl = nil
        pendingScrubValue = nil
        scrubGeneration &+= 1
        bottomBar.isHidden = true
        audioGroup = nil
        subtitleGroup = nil
        trackGroupsLoadedFor = nil
        sidecarGeneration &+= 1
        sidecarSubtitles.removeAll()
        nextSidecarOrder = 0
        activeSidecarSubtitleIndex = nil
        renderedSubtitleText = nil
        renderedSubtitleAppearance = nil
        subtitleLabel.attributedText = nil
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
    let customizeAction: (() -> Void)?
    let customizeEnabled: Bool
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
                        actionButtons
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
                        Section {
                            actionButtons
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

    @ViewBuilder
    private var actionButtons: some View {
        if let moreAction {
            Button("Get More from OpenSubtitles") {
                dismiss()
                DispatchQueue.main.async { moreAction() }
            }
        }
        if let customizeAction {
            Button("Customize Subtitles") {
                dismiss()
                DispatchQueue.main.async { customizeAction() }
            }
            .disabled(!customizeEnabled)
            .accessibilityIdentifier("player.customizeSubtitles")
            .accessibilityHint(
                customizeEnabled
                    ? "Adjust the selected sidecar subtitle"
                    : "Select a downloaded or sidecar subtitle to customize"
            )
        }
    }
}

}

@MainActor
final class SubtitleCustomizationModel: ObservableObject {
    @Published private(set) var appearance: SubtitleAppearance
    @Published private(set) var delay: TimeInterval
    @Published var isExternalPlaybackActive = false

    private let onChange: (SubtitleAppearance, TimeInterval) -> Void

    init(onChange: @escaping (SubtitleAppearance, TimeInterval) -> Void) {
        appearance = SubtitlePreferences.appearance
        delay = SubtitlePreferences.delay
        self.onChange = onChange
    }

    func updateAppearance(_ update: (inout SubtitleAppearance) -> Void) {
        var next = appearance
        update(&next)
        SubtitlePreferences.appearance = next
        appearance = SubtitlePreferences.appearance
        onChange(appearance, delay)
    }

    func setDelay(_ value: TimeInterval) {
        SubtitlePreferences.delay = min(max(value, -10), 10)
        delay = SubtitlePreferences.delay
        onChange(appearance, delay)
    }

    func adjustFontSize(by delta: CGFloat) {
        updateAppearance {
            $0.fontSizePoints = min(max(($0.fontSizePoints + delta).rounded(), 12), 40)
            $0.fontSizePoints = ($0.fontSizePoints / 2).rounded() * 2
        }
    }

    func reset() {
        SubtitlePreferences.reset()
        appearance = SubtitlePreferences.appearance
        delay = SubtitlePreferences.delay
        onChange(appearance, delay)
    }
}

private struct SubtitleCustomizationSheet: View {
    @ObservedObject var model: SubtitleCustomizationModel
    @Environment(\.dismiss) private var dismiss

    private let textColors: [SubtitleColorPreset] = [
        .white, .gold, .cyan, .red, .brightGreen, .purple, .orange, .blue, .black
    ]
    private let backgroundColors: [SubtitleColorPreset] = [
        .transparent, .black, .navy, .darkRed, .darkGreen, .darkBlue
    ]
    private let outlineColors: [SubtitleColorPreset] = [.black, .white, .cyan, .red]

    var body: some View {
        NavigationStack {
            Form {
                Section("Timing") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Subtitle delay")
                            Spacer()
                            Text(String(format: "%+.1f s", model.delay))
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { model.delay },
                                set: { model.setDelay($0) }
                            ),
                            in: -10...10,
                            step: 0.1
                        )
                        .accessibilityIdentifier("player.subtitle.delay")
                        .accessibilityLabel("Subtitle delay")
                        .accessibilityValue(String(format: "%+.1f seconds", model.delay))
                        Text("Positive values show subtitles later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Appearance") {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Button {
                            model.adjustFontSize(by: -2)
                        } label: {
                            Image(systemName: "minus")
                        }
                        .accessibilityLabel("Decrease subtitle font size")
                        Text("\(Int(model.appearance.fontSizePoints)) pt")
                            .frame(minWidth: 58)
                            .accessibilityLabel("Subtitle font size")
                            .accessibilityValue("\(Int(model.appearance.fontSizePoints)) points")
                        Button {
                            model.adjustFontSize(by: 2)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Increase subtitle font size")
                    }
                    .accessibilityIdentifier("player.subtitle.fontSize")

                    Toggle(
                        "Bold",
                        isOn: Binding(
                            get: { model.appearance.bold },
                            set: { value in model.updateAppearance { $0.bold = value } }
                        )
                    )
                    .accessibilityIdentifier("player.subtitle.bold")

                    colorSection(
                        title: "Text color",
                        presets: textColors,
                        selected: model.appearance.textColor,
                        identifier: "player.subtitle.textColor"
                    ) { preset in
                        model.updateAppearance { $0.textColor = preset }
                    }

                    opacitySlider(
                        title: "Text opacity",
                        value: Binding(
                            get: { Double(model.appearance.textOpacity) },
                            set: { value in model.updateAppearance { $0.textOpacity = CGFloat(value) } }
                        ),
                        identifier: "player.subtitle.textOpacity"
                    )

                    colorSection(
                        title: "Background color",
                        presets: backgroundColors,
                        selected: model.appearance.backgroundColor,
                        identifier: "player.subtitle.backgroundColor"
                    ) { preset in
                        model.updateAppearance { $0.backgroundColor = preset }
                    }

                    opacitySlider(
                        title: "Background opacity",
                        value: Binding(
                            get: { Double(model.appearance.backgroundOpacity) },
                            set: { value in model.updateAppearance { $0.backgroundOpacity = CGFloat(value) } }
                        ),
                        identifier: "player.subtitle.backgroundOpacity"
                    )

                    Toggle(
                        "Outline",
                        isOn: Binding(
                            get: { model.appearance.outlineEnabled },
                            set: { value in model.updateAppearance { $0.outlineEnabled = value } }
                        )
                    )
                    .accessibilityIdentifier("player.subtitle.outline")

                    colorSection(
                        title: "Outline color",
                        presets: outlineColors,
                        selected: model.appearance.outlineColor,
                        identifier: "player.subtitle.outlineColor",
                        enabled: model.appearance.outlineEnabled
                    ) { preset in
                        model.updateAppearance {
                            $0.outlineEnabled = true
                            $0.outlineColor = preset
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Vertical position")
                            Spacer()
                            Text("\(Int(model.appearance.bottomInset)) pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(model.appearance.bottomInset) },
                                set: { value in model.updateAppearance { $0.bottomInset = CGFloat(value) } }
                            ),
                            in: 40...300,
                            step: 10
                        )
                        .accessibilityIdentifier("player.subtitle.bottomInset")
                        .accessibilityLabel("Subtitle vertical position")
                        .accessibilityValue("\(Int(model.appearance.bottomInset)) points")
                    }
                }

                if model.isExternalPlaybackActive {
                    Section {
                        Label(
                            "AirPlay devices control final caption appearance.",
                            systemImage: "airplayvideo"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Reset Defaults") {
                        model.reset()
                    }
                    .accessibilityIdentifier("player.subtitle.reset")
                }
            }
            .navigationTitle("Customize Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func opacitySlider(
        title: String,
        value: Binding<Double>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1, step: 0.1)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
        }
    }

    @ViewBuilder
    private func colorSection(
        title: String,
        presets: [SubtitleColorPreset],
        selected: SubtitleColorPreset,
        identifier: String,
        enabled: Bool = true,
        onSelect: @escaping (SubtitleColorPreset) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            onSelect(preset)
                        } label: {
                            Circle()
                                .fill(Color(uiColor: preset.color))
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Circle()
                                        .stroke(
                                            preset == selected ? Color.primary : Color.secondary.opacity(0.45),
                                            lineWidth: preset == selected ? 3 : 1
                                        )
                                }
                        }
                        .disabled(!enabled)
                        .accessibilityLabel(preset.displayName)
                        .accessibilityValue(preset == selected ? "Selected" : "")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier(identifier)
        }
        .opacity(enabled ? 1 : 0.45)
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
