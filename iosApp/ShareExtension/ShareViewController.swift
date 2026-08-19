import UIKit
import Social

/// Share-sheet entry: grabs the first URL from the shared content and hands it
/// to Rigel via the rigel:// x-callback scheme (x-source=share).
final class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        defer { extensionContext?.completeRequest(returningItems: nil) }
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else { return }

        var found: String?
        let group = DispatchGroup()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier("public.url") else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.url", options: nil) { (url, _) in
                if let u = url as? URL, found == nil {
                    found = u.absoluteString
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard let url = found else { return }
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = url.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let target = "rigel://x-callback-url/play?url=\(encoded)&x-source=share"
            if let targetURL = URL(string: target) {
                self.extensionContext?.open(targetURL, completionHandler: nil)
            }
        }
    }

    override func configurationItems() -> [Any]! { [] }
}
