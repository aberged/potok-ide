import Capacitor
import UIKit

/// Content shared to Potok from other apps. The Share Extension
/// (ShareExtension/ShareViewController.swift) copies it into the App Group
/// container, `share_inbox/<id>/` with a `share.json`, and opens
/// `potok://share/<id>`; the web app (assets/js/share_inbox.js) reads it from
/// here once a group is picked. The same API as Android's ShareInboxPlugin.java.
@objc(ShareInboxPlugin)
public class ShareInboxPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ShareInboxPlugin"
    public let jsName = "ShareInbox"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getPending", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readChunk", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clear", returnType: CAPPluginReturnPromise)
    ]

    private static let manifestName = "share.json"
    private static let maxAge: TimeInterval = 24 * 60 * 60
    private static let maxChunk = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "rs.potok.ide.share-inbox")
    private var announcedShareId: String?

    override public func load() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        queue.async { self.removeStaleShares() }
    }

    // Besides the URL the extension opens: the app may come to the front
    // another way, or the extension may fail to open it.
    @objc private func applicationDidBecomeActive() {
        queue.async {
            guard let id = self.readPendingShare()?["id"] as? String, id != self.announcedShareId else {
                return
            }

            self.announcedShareId = id
            self.notifyListeners("shareReceived", data: ["id": id], retainUntilConsumed: true)
        }
    }

    @objc func getPending(_ call: CAPPluginCall) {
        queue.async {
            if let share = self.readPendingShare() {
                call.resolve(["share": share])
            } else {
                call.resolve()
            }
        }
    }

    @objc func readChunk(_ call: CAPPluginCall) {
        let shareId = call.getString("shareId") ?? ""
        let fileId = call.getString("fileId") ?? ""
        let offset = max(0, call.getInt("offset") ?? 0)
        let length = max(1, min(call.getInt("length") ?? Self.maxChunk, Self.maxChunk))

        queue.async {
            guard let url = self.sharedFile(shareId: shareId, fileId: fileId) else {
                call.reject("Shared file not found")
                return
            }

            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                try handle.seek(toOffset: UInt64(offset))
                let data = handle.readData(ofLength: length)
                call.resolve(["data": data.base64EncodedString()])
            } catch {
                call.reject("Could not read the shared file", nil, error)
            }
        }
    }

    @objc func clear(_ call: CAPPluginCall) {
        let shareId = call.getString("shareId") ?? ""

        queue.async {
            if Self.validShareId(shareId), let inbox = Self.inboxURL() {
                try? FileManager.default.removeItem(at: inbox.appendingPathComponent(shareId))
            }

            call.resolve()
        }
    }

    /// The App Group container's inbox, or nil when the app has no App Group.
    static func inboxURL() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PotokAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }

        return container.appendingPathComponent("share_inbox", isDirectory: true)
    }

    private static func validShareId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The newest share, without where its files lie.
    private func readPendingShare() -> [String: Any]? {
        guard let inbox = Self.inboxURL(),
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return nil
        }

        let newest = dirs
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.manifestName).path) }
            .max { modificationDate($0) < modificationDate($1) }

        guard let dir = newest, var share = readManifest(dir) else {
            return nil
        }

        let files = (share["files"] as? [[String: Any]]) ?? []
        share["files"] = files.map { file -> [String: Any] in
            var file = file
            file.removeValue(forKey: "path")
            return file
        }

        return share
    }

    private func sharedFile(shareId: String, fileId: String) -> URL? {
        guard Self.validShareId(shareId), let inbox = Self.inboxURL() else {
            return nil
        }

        let dir = inbox.appendingPathComponent(shareId, isDirectory: true)
        let files = (readManifest(dir)?["files"] as? [[String: Any]]) ?? []

        guard let file = files.first(where: { ($0["id"] as? String) == fileId }),
              let path = file["path"] as? String,
              !path.contains("/"), path != "..", path != "." else {
            return nil
        }

        return dir.appendingPathComponent(path)
    }

    private func readManifest(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.manifestName)) else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func removeStaleShares() {
        guard let inbox = Self.inboxURL(),
              let dirs = try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return
        }

        for dir in dirs where Date().timeIntervalSince(modificationDate(dir)) > Self.maxAge {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
