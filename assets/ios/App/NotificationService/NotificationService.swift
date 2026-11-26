import Intents
import UserNotifications

/// Adds the picture to a Potok notification before iOS shows it. The server
/// sends `mutable-content` with every alert (`PotokIde.PushNotifications.FCM`),
/// and the FCM data the notification carries says what to show:
///
/// - a message, mention, reply or reaction becomes a communication
///   notification, as in messaging apps: the sender's picture (`sender_icon`),
///   and for a group its name (`title`) and picture (`icon`);
/// - anything else gets its picture (`icon`) as an attachment.
///
/// If the pictures do not come in time, the notification goes as it came.
final class NotificationService: UNNotificationServiceExtension {
    private static let chatKinds: Set<String> = ["message", "mention", "reply", "reaction"]
    private static let timeout: TimeInterval = 5

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?
    private let lock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        original = request.content

        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            deliver(request.content)
            return
        }

        let info = content.userInfo
        let kind = info["kind"] as? String ?? ""

        if Self.chatKinds.contains(kind) {
            communicate(content, info: info)
        } else {
            attach(content, info: info)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let original {
            deliver(original)
        }
    }

    // Hands the content to iOS once: the time running out and a late picture
    // must not both deliver it.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }

    private func communicate(_ content: UNMutableNotificationContent, info: [AnyHashable: Any]) {
        let senderName = (info["sender"] as? String) ?? content.title
        let direct = (info["direct"] as? String) == "true"
        let conversation = (info["group_id"] as? String) ?? content.threadIdentifier

        let pictures = DispatchGroup()
        var senderPicture: Data?
        var groupPicture: Data?

        pictures.enter()
        fetch(info["sender_icon"] as? String) { data in
            senderPicture = data
            pictures.leave()
        }

        if !direct {
            pictures.enter()
            fetch(info["icon"] as? String) { data in
                groupPicture = data
                pictures.leave()
            }
        }

        pictures.notify(queue: .global()) {
            let sender = INPerson(
                personHandle: INPersonHandle(value: senderName, type: .unknown),
                nameComponents: nil,
                displayName: senderName,
                image: senderPicture.map { INImage(imageData: $0) },
                contactIdentifier: nil,
                customIdentifier: "sender:\(senderName)",
                isMe: false
            )

            let me = INPerson(
                personHandle: INPersonHandle(value: "me", type: .unknown),
                nameComponents: nil,
                displayName: nil,
                image: nil,
                contactIdentifier: nil,
                customIdentifier: "me",
                isMe: true
            )

            let intent = INSendMessageIntent(
                recipients: direct ? [me] : [me, sender],
                outgoingMessageType: .outgoingMessageText,
                content: content.body,
                speakableGroupName: direct ? nil : INSpeakableString(spokenPhrase: content.title),
                conversationIdentifier: conversation,
                serviceName: nil,
                sender: sender,
                attachments: nil
            )

            if let groupPicture {
                intent.setImage(INImage(imageData: groupPicture), forParameterNamed: \.speakableGroupName)
            }

            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate(completion: nil)

            if let updated = try? content.updating(from: intent) {
                self.deliver(updated)
            } else {
                self.deliver(content)
            }
        }
    }

    private func attach(_ content: UNMutableNotificationContent, info: [AnyHashable: Any]) {
        fetch(info["icon"] as? String) { data in
            if let data, let attachment = Self.attachment(data) {
                content.attachments = [attachment]
            }

            self.deliver(content)
        }
    }

    private static func attachment(_ data: Data) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "picture", url: url, options: nil)
        } catch {
            return nil
        }
    }

    // The pictures are PNG addresses that work without a session
    // (`PotokIdeWeb.Avatars`).
    private func fetch(_ address: String?, completion: @escaping (Data?) -> Void) {
        guard
            let address,
            let url = URL(string: address),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else {
            completion(nil)
            return
        }

        let request = URLRequest(url: url, timeoutInterval: Self.timeout)

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<300).contains(status) ? data : nil)
        }.resume()
    }
}
