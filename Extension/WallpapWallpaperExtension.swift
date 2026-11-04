import ExtensionFoundation
import Foundation
import ObjectiveC

/// Provider identifier written into the wallpaper store for our choices.
let providerID = "local.dolbobob.wallpap.wallpaper"

@main
struct WallpapWallpaperExtension: AppExtension {
    init() {
        ExtLog.write("extension launched, private framework loaded=\(PrivateBridge.isLoaded)")
    }

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: { connection in
            guard let exported = PrivateBridge.extensionProtocol, let proxy = PrivateBridge.proxyProtocol else {
                ExtLog.write("protocols unavailable, rejecting connection")
                return false
            }
            class_addProtocol(XPCHandler.self, exported)
            let handler = XPCHandler()
            connection.exportedInterface = NSXPCInterface(with: exported)
            connection.remoteObjectInterface = NSXPCInterface(with: proxy)
            connection.exportedObject = handler
            connection.invalidationHandler = {
                ExtLog.write("connection invalidated")
                DispatchQueue.main.async { handler.invalidateAll() }
            }
            connection.resume()
            ExtLog.write("accepted connection from pid \(connection.processIdentifier)")
            return true
        })
    }
}

/// Implements `WallpaperExtensionXPCProtocol` (selectors and argument types match the private protocol).
final class XPCHandler: NSObject, @unchecked Sendable {
    typealias ErrorReply = (NSError?) -> Void
    typealias ObjectReply = (NSObject?, NSError?) -> Void

    @MainActor private var instances: [String: VideoWallpaper] = [:]
    @MainActor private var monitor: Timer?

    /// Re-applies settings / power state every 2 s (settings.json is re-read only when it changes).
    @MainActor private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.instances.values.forEach { $0.applyPlaybackState() } }
        }
    }

    private func unsupported(_ what: String) -> NSError {
        NSError(domain: "local.dolbobob.wallpap", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(what) is not supported"])
    }

    @MainActor func invalidateAll() {
        monitor?.invalidate()
        monitor = nil
        instances.values.forEach { $0.invalidate() }
        instances.removeAll()
    }

    // MARK: Wallpaper lifecycle

    @objc(acquireWithId:request:reply:)
    func acquire(_ id: NSObject, request: NSObject, reply: @escaping ObjectReply) {
        let key = PrivateBridge.wallpaperID(id)
        let req = PrivateBridge.payload(request)
        let size = PrivateBridge.value(req, "destination", "size") as? CGSize ?? CGSize(width: 1920, height: 1080)
        let scale = PrivateBridge.value(req, "destination", "scaleFactor") as? CGFloat ?? 2
        let config = PrivateBridge.value(req, "descriptor", "configuration") as? Data
        let mode = PrivateBridge.caseName(PrivateBridge.value(req, "presentationMode")) ?? "?"
        let activity = PrivateBridge.caseName(PrivateBridge.value(req, "activityState")) ?? "?"
        ExtLog.write("acquire \(key) size=\(size) scale=\(scale) mode=\(mode) activity=\(activity) preview=\(PrivateBridge.value(req, "isPreview") ?? "?")")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.instances[key]?.invalidate()
                let item = LibraryReader.item(forConfiguration: config)
                guard let wallpaper = VideoWallpaper(item: item, size: size, scale: scale),
                      let ctx = PrivateBridge.remoteContext(wallpaper.contextID)
                else {
                    reply(nil, self.unsupported("remote context"))
                    return
                }
                wallpaper.update(size: nil, scale: nil, presentationMode: mode, active: activity != "suspended")
                self.instances[key] = wallpaper
                self.startMonitor()
                reply(ctx, nil)
            }
        }
    }

    @objc(updateWithId:request:reply:)
    func update(_ id: NSObject, request: NSObject, reply: @escaping ErrorReply) {
        let key = PrivateBridge.wallpaperID(id)
        let req = PrivateBridge.payload(request)
        let size = PrivateBridge.value(req, "destination", "size") as? CGSize
        let scale = PrivateBridge.value(req, "destination", "scaleFactor") as? CGFloat
        let activity = PrivateBridge.caseName(PrivateBridge.value(req, "activityState")) ?? "active"
        let mode = PrivateBridge.caseName(PrivateBridge.value(req, "presentationMode")) ?? "?"
        ExtLog.write("update \(key) size=\(String(describing: size)) mode=\(mode) activity=\(activity)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.instances[key]?.update(size: size, scale: scale, presentationMode: mode,
                                            active: activity != "suspended")
                reply(nil)
            }
        }
    }

    @objc(invalidateWithId:reply:)
    func invalidate(_ id: NSObject, reply: @escaping ErrorReply) {
        let key = PrivateBridge.wallpaperID(id)
        ExtLog.write("invalidate \(key)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.instances.removeValue(forKey: key)?.invalidate()
                reply(nil)
            }
        }
    }

    @objc(snapshotWithId:reply:)
    func snapshot(_ id: NSObject, reply: @escaping ObjectReply) {
        let key = PrivateBridge.wallpaperID(id)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let surface = self.instances[key]?.makeSnapshot(),
                      let snap = PrivateBridge.snapshot(surface)
                else {
                    ExtLog.write("snapshot \(key) unavailable")
                    reply(nil, self.unsupported("snapshot"))
                    return
                }
                reply(snap, nil)
            }
        }
    }

    // MARK: Settings

    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettingsViewModels(_ types: NSObject, reply: @escaping ObjectReply) {
        ExtLog.write("provideSettingsViewModels \(PrivateBridge.payload(types) ?? "-")")
        reply(PrivateBridge.settingsViewModels(Self.viewModels()), nil)
    }

    static func viewModels() -> [String: Any] {
        let empty: [String: Any] = [:]
        let items: [[String: Any]] = LibraryReader.videos.enumerated().map { index, item in
            let thumb: [String: Any] = ["image": ["url": ["relative": LibraryReader.thumbURL(item).absoluteString]]]
            let choiceID: [String: Any] = ["descriptor": [
                "provider": providerID, "files": [Any](), "configuration": LibraryReader.configuration(for: item),
            ]]
            return [
                "id": ["id": item.id.uuidString],
                "localizedName": item.name,
                "thumbnail": thumb,
                "choice": ["id": choiceID, "localizedDescription": item.name, "thumbnail": thumb,
                           "isDownloaded": true, "options": [Any]()],
                "contentBadge": ["video": empty],
                "showInTopLevel": true,
                "sortOrder": index,
                "disposability": ["none": empty],
            ]
        }
        let group: [String: Any] = [
            "id": ["id": "wallpap.videos"], "localizedName": "Wallpap",
            "disposability": ["none": empty], "sortID": ["id": "wallpap.videos"],
            "shouldHideItemLabels": false, "sortOrder": 0, "items": items,
        ]
        return ["desktop": ["groups": items.isEmpty ? [] : [group],
                            "refreshPolicy": ["default": empty], "isModificationDisabled": false]]
    }

    // MARK: Choices / downloads (everything is local and always "downloaded")

    @objc(isChoiceDownloadedWith:reply:)
    func isChoiceDownloaded(_ choice: NSObject, reply: @escaping (NSNumber?, NSError?) -> Void) { reply(NSNumber(value: true), nil) }

    @objc(downloadWithChoiceID:reply:)
    func download(_ choice: NSObject, reply: @escaping ErrorReply) -> Progress {
        let p = Progress(totalUnitCount: 1)
        p.completedUnitCount = 1
        reply(nil)
        return p
    }

    @objc(cancelDownloadFor:reply:) func cancelDownload(_ c: NSObject, reply: @escaping ErrorReply) { reply(nil) }
    @objc(pauseDownloadFor:reply:) func pauseDownload(_ c: NSObject, reply: @escaping ErrorReply) { reply(nil) }
    @objc(resumeDownloadFor:reply:) func resumeDownload(_ c: NSObject, reply: @escaping ErrorReply) { reply(nil) }
    @objc(removeDownloadFor:reply:) func removeDownload(_ c: NSObject, reply: @escaping ErrorReply) { reply(nil) }

    @objc(selectedChoicesDidChangeFor:reply:)
    func selectedChoicesDidChange(_ ids: NSObject, reply: @escaping ErrorReply) {
        ExtLog.write("selectedChoicesDidChange \(PrivateBridge.payload(ids) ?? "-")")
        reply(nil)
    }

    @objc(migrateSelectedChoiceFor:reply:)
    func migrateSelectedChoice(_ choice: NSObject, reply: @escaping ObjectReply) { reply(choice, nil) }

    @objc(migrateFrom:to:reply:)
    func migrate(_ from: NSObject, to: NSObject, reply: @escaping ErrorReply) { reply(nil) }

    @objc(addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:)
    func addChoiceRequest(_ request: NSObject, onBehalfOfProcess token: NSObject, reply: @escaping ObjectReply) {
        reply(nil, unsupported("adding choices"))
    }

    @objc(removeChoiceRequestWithChoiceRequest:reply:)
    func removeChoiceRequest(_ request: NSObject, reply: @escaping ErrorReply) { reply(nil) }

    // MARK: Shuffle / misc

    @objc(canSkipShuffledContentWithId:reply:)
    func canSkipShuffledContent(_ id: NSObject, reply: @escaping (Bool, NSError?) -> Void) { reply(false, nil) }

    @objc(skipShuffledContentWithId:reply:)
    func skipShuffledContent(_ id: NSObject, reply: @escaping ErrorReply) { reply(nil) }

    @objc(handleNotificationWithNamed:reply:)
    func handleNotification(_ name: NSString, reply: @escaping ErrorReply) {
        ExtLog.write("notification \(name)")
        reply(nil)
    }

    @objc(invokeContextMenuActionWithMenuItemID:groupItemID:reply:)
    func invokeContextMenuAction(_ item: NSString, groupItemID: NSString, reply: @escaping ErrorReply) { reply(nil) }

    @objc(handleDebugRequestFor:reply:)
    func handleDebugRequest(_ request: NSObject, reply: @escaping ObjectReply) { reply(PrivateBridge.debugSuccess(), nil) }
}
