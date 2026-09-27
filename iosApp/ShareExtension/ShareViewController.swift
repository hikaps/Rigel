import UIKit
import Social

/// Serializes shared-content loading and the final handoff. The seams keep
/// lifecycle behavior testable without constructing an extension context.
final class ShareHandoffCoordinator<Provider> {
    typealias LoadProvider = (Provider, @escaping (Result<URL, Error>) -> Void) -> Void
    typealias OpenURL = (URL, @escaping () -> Void) -> Void
    typealias Complete = () -> Void
    typealias ScheduleTimeout = (@escaping () -> Void) -> Void

    private let providers: [Provider]
    private let loadProvider: LoadProvider
    private let openURL: OpenURL
    private let complete: Complete
    private let scheduleTimeout: ScheduleTimeout

    private var started = false
    private var didFinish = false
    private var nextProviderIndex = 0
    private var activeProviderIndex: Int?
    private var openInFlight = false

    init(
        providers: [Provider],
        load: @escaping LoadProvider,
        openURL: @escaping OpenURL,
        complete: @escaping Complete,
        scheduleTimeout: @escaping ScheduleTimeout
    ) {
        self.providers = providers
        self.loadProvider = load
        self.openURL = openURL
        self.complete = complete
        self.scheduleTimeout = scheduleTimeout
    }

    func start() {
        guard !started else { return }
        started = true
        scheduleTimeout { [weak self] in
            self?.finish()
        }
        loadNextProvider()
    }

    private func loadNextProvider() {
        guard started, !didFinish, !openInFlight else { return }
        guard providers.indices.contains(nextProviderIndex) else {
            finish()
            return
        }

        let providerIndex = nextProviderIndex
        nextProviderIndex += 1
        activeProviderIndex = providerIndex
        loadProvider(providers[providerIndex]) { [weak self] result in
            self?.providerFinished(at: providerIndex, result: result)
        }
    }

    private func providerFinished(at index: Int, result: Result<URL, Error>) {
        guard started,
              !didFinish,
              !openInFlight,
              activeProviderIndex == index else { return }
        activeProviderIndex = nil

        switch result {
        case .failure:
            loadNextProvider()
        case .success(let url):
            openInFlight = true
            openURL(url) { [weak self] in
                guard let self, !self.didFinish, self.openInFlight else { return }
                self.openInFlight = false
                self.finish()
            }
        }
    }

    private func finish() {
        guard started, !didFinish else { return }
        didFinish = true
        activeProviderIndex = nil
        openInFlight = false
        complete()
    }
}

/// Share-sheet entry: grabs the first URL from the shared content and hands it
/// to Rigel via the rigel:// x-callback scheme (x-source=share).
final class ShareViewController: SLComposeServiceViewController {
    private static let requestTimeout: TimeInterval = 15
    private static let urlTypeIdentifier = "public.url"

    private var handoffCoordinator: ShareHandoffCoordinator<NSItemProvider>?
    private var didCompleteRequest = false

    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        guard !didCompleteRequest, handoffCoordinator == nil else { return }

        let providers = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments ?? []
        let eligibleProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(Self.urlTypeIdentifier)
        }
        let coordinator = ShareHandoffCoordinator(
            providers: eligibleProviders,
            load: { provider, completion in
                provider.loadItem(forTypeIdentifier: Self.urlTypeIdentifier, options: nil) { item, error in
                    DispatchQueue.main.async {
                        if let url = Self.url(from: item) {
                            completion(.success(url))
                        } else {
                            completion(.failure(error ?? HandoffError.unsupportedItem))
                        }
                    }
                }
            },
            openURL: { [weak self] sharedURL, completion in
                guard let self,
                      let targetURL = Self.targetURL(for: sharedURL),
                      let context = self.extensionContext else {
                    completion()
                    return
                }
                context.open(targetURL) { _ in
                    DispatchQueue.main.async {
                        completion()
                    }
                }
            },
            complete: { [weak self] in
                guard let self else { return }
                self.didCompleteRequest = true
                self.extensionContext?.completeRequest(returningItems: nil)
            },
            scheduleTimeout: { completion in
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(Self.requestTimeout))) {
                    completion()
                }
            }
        )
        handoffCoordinator = coordinator
        coordinator.start()
    }

    /// Only URL objects are accepted from a public.url provider. Other payload
    /// types are unsupported and follow the same explicit skip path as errors.
    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        return nil
    }

    /// Kept pure so the x-callback construction can be smoke-tested without
    /// needing to host the share extension UI.
    static func targetURL(for sharedURL: URL) -> URL? {
        let value = sharedURL.absoluteString
        guard !value.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "rigel://x-callback-url/play?url=\(encoded)&x-source=share")
    }

    override func configurationItems() -> [Any]! { [] }
}

private enum HandoffError: Error {
    case unsupportedItem
}
