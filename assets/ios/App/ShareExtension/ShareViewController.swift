import UIKit
import UniformTypeIdentifiers

/// "Potok" in the share sheet. It copies what was shared into the App Group
/// container, the way the app's ShareInboxPlugin reads it (`share_inbox/<id>/`
/// with a `share.json`), and opens the app with `potok://share/<id>`, where
/// the person picks the group to post it in.
class ShareViewController: UIViewController {
    private static let maxFiles = 50
    private static let manifestName = "share.json"

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let stack = UIStackView()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        label.text = Self.text(.opening)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor)
        ])

        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !started else {
            return
        }

        started = true
        storeShare()
    }

    private func storeShare() {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = Array(items.flatMap { $0.attachments ?? [] }.prefix(Self.maxFiles))
        let title = items.compactMap { $0.attributedTitle?.string }.first { !$0.isEmpty } ?? ""

        guard let inbox = Self.inboxURL() else {
            showMessage(Self.text(.failed))
            return
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let dir = inbox.appendingPathComponent(id, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            showMessage(Self.text(.failed))
            return
        }

        let lock = NSLock()
        let group = DispatchGroup()
        var texts = [Int: String]()
        var files = [Int: [String: Any]]()

        for (index, provider) in providers.enumerated() {
            group.enter()

            load(provider, index: index, into: dir) { text, file in
                lock.lock()
                texts[index] = text
                files[index] = file
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let manifest: [String: Any] = [
                "id": id,
                "title": title,
                "texts": texts.sorted { $0.key < $1.key }.map { $0.value },
                "files": files.sorted { $0.key < $1.key }.map { $0.value }
            ]

            guard !title.isEmpty || !texts.isEmpty || !files.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: manifest),
                  (try? data.write(to: dir.appendingPathComponent(Self.manifestName))) != nil else {
                try? FileManager.default.removeItem(at: dir)
                self.showMessage(Self.text(.failed))
                return
            }

            // Only the newest share is kept.
            let others = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []

            for other in others where other.lastPathComponent != id {
                try? FileManager.default.removeItem(at: other)
            }

            if let url = URL(string: "potok://share/\(id)"), self.openApp(url) {
                self.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self.showMessage(Self.text(.openApp))
            }
        }
    }

    // A web link or text comes back as text; anything else is copied as a file.
    private func load(
        _ provider: NSItemProvider,
        index: Int,
        into dir: URL,
        completion: @escaping (String?, [String: Any]?) -> Void
    ) {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                completion((item as? URL)?.absoluteString ?? (item as? String), nil)
            }
            return
        }

        // Text files from the Files app have a name; shared text has none.
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), provider.suggestedName == nil {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    completion(text, nil)
                } else if let data = item as? Data {
                    completion(String(data: data, encoding: .utf8), nil)
                } else {
                    completion(nil, nil)
                }
            }
            return
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .data) == true || UTType($0)?.conforms(to: .package) == true
        } ?? provider.registeredTypeIdentifiers.first

        guard let typeIdentifier else {
            completion(nil, nil)
            return
        }

        // The file is only there until the handler returns, so it is copied here.
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            guard let url else {
                completion(nil, nil)
                return
            }

            let type = UTType(typeIdentifier)
            let name = Self.fileName(suggested: provider.suggestedName, url: url, type: type)
            let fileId = String(index)
            let target = dir.appendingPathComponent("\(fileId)-\(Self.storedName(name))")

            do {
                try FileManager.default.copyItem(at: url, to: target)
                let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                completion(nil, [
                    "id": fileId,
                    "name": name,
                    "mimeType": type?.preferredMIMEType ?? "",
                    "size": size,
                    "path": target.lastPathComponent
                ])
            } catch {
                completion(nil, nil)
            }
        }
    }

    // Share extensions have no API to open their app; UIApplication answers
    // `openURL:options:completionHandler:` when reached through the responder
    // chain. Called through the runtime because the extension SDK hides it.
    private func openApp(_ url: URL) -> Bool {
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self

        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }

            responder = current.next
        }

        return false
    }

    private func showMessage(_ text: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = text
        label.textColor = .label

        let button = UIButton(type: .system)
        button.setTitle("OK", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(done), for: .touchUpInside)
        stack.addArrangedSubview(button)
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func inboxURL() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PotokAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }

        return container.appendingPathComponent("share_inbox", isDirectory: true)
    }

    private static func fileName(suggested: String?, url: URL, type: UTType?) -> String {
        var name = (suggested?.isEmpty == false ? suggested : nil) ?? url.lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "_")

        // Photos suggests names without an extension ("IMG_0042").
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
            name += ".\(ext)"
        }

        return String(name.prefix(255))
    }

    private static func storedName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let stored = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(stored.suffix(80))
    }

    private enum Message {
        case opening, openApp, failed
    }

    private static func text(_ message: Message) -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let language = preferred.hasPrefix("sr-Cyrl") ? "sr-Cyrl" : String(preferred.prefix(2))

        switch (message, language) {
        case (.opening, "sr"): return "Otvaram Potok…"
        case (.opening, "sr-Cyrl"): return "Отварам Поток…"
        case (.opening, _): return "Opening Potok…"
        case (.openApp, "sr"): return "Otvori Potok da završiš deljenje."
        case (.openApp, "sr-Cyrl"): return "Отвори Поток да завршиш дељење."
        case (.openApp, _): return "Open Potok to finish sharing."
        case (.failed, "sr"): return "Ovo nije moguće podeliti u Potok."
        case (.failed, "sr-Cyrl"): return "Ово није могуће поделити у Поток."
        case (.failed, _): return "This cannot be shared to Potok."
        }
    }
}
