import UIKit
import Social

/// Share-sheet entry: grabs the first URL from the shared content and hands it
/// to Rigel via the rigel:// x-callback scheme (x-source=share).
final class ShareViewController: SLComposeServiceViewController {
    private static let requestTimeout: TimeInterval = 15
    private static let urlTypeIdentifier = "public.url"

    private var activeRequestID: UUID?
    private var nextProviderIndex: Int?
    private var timeoutWorkItem: DispatchWorkItem?
    private var didCompleteRequest = false

    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        guard !didCompleteRequest, activeRequestID == nil else { return }

        let requestID = UUID()
        activeRequestID = requestID
        nextProviderIndex = 0
        let providers = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments ?? []
        let eligibleProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(Self.urlTypeIdentifier)
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.finishRequest(id: requestID)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(Int(Self.requestTimeout)),
            execute: timeout
        )
        loadNextProvider(
            at: 0,
            providers: eligibleProviders,
            requestID: requestID
        )
    }

    /// Loads eligible providers in attachment order. A provider that fails or
    /// returns a non-URL payload is explicitly skipped before trying the next
    /// one, so completion order cannot change which URL wins.
    private func loadNextProvider(
        at index: Int,
        providers: [NSItemProvider],
        requestID: UUID
    ) {
        guard activeRequestID == requestID,
              !didCompleteRequest,
              nextProviderIndex == index else { return }
        guard providers.indices.contains(index) else {
            finishRequest(id: requestID)
            return
        }

        let provider = providers[index]
        provider.loadItem(forTypeIdentifier: Self.urlTypeIdentifier, options: nil) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.activeRequestID == requestID,
                      !self.didCompleteRequest,
                      self.nextProviderIndex == index else { return }
                self.nextProviderIndex = index + 1
                guard let url = Self.url(from: item) else {
                    self.loadNextProvider(at: index + 1, providers: providers, requestID: requestID)
                    return
                }
                self.open(url: url, requestID: requestID)
            }
        }
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

    private func open(url: URL, requestID: UUID) {
        guard activeRequestID == requestID, !didCompleteRequest else { return }
        guard let targetURL = Self.targetURL(for: url),
              let context = extensionContext else {
            finishRequest(id: requestID)
            return
        }

        context.open(targetURL) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.finishRequest(id: requestID)
            }
        }
    }

    private func finishRequest(id: UUID) {
        guard activeRequestID == id, !didCompleteRequest else { return }
        didCompleteRequest = true
        activeRequestID = nil
        nextProviderIndex = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        extensionContext?.completeRequest(returningItems: nil)
    }

    override func configurationItems() -> [Any]! { [] }
}
