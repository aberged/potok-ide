import UIKit
import Capacitor
import FirebaseCore
import FirebaseMessaging

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, MessagingDelegate {

    private let nativePushRegistrationEvent = "potokNativePushRegistration"
    private let nativePushRegistrationErrorEvent = "potokNativePushRegistrationError"
    private var pendingFCMToken: String?
    private var pendingFCMErrorMessage: String?

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if FirebaseApp.app() == nil, let options = firebaseOptions() {
            FirebaseApp.configure(options: options)
            Messaging.messaging().delegate = self
            fetchFCMRegistrationToken()
        }

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        flushPendingNativePushEvents()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)

        guard FirebaseApp.app() != nil else {
            pendingFCMErrorMessage = "Firebase is not configured for iOS push notifications. Add GoogleService-Info.plist before registering this build."
            flushPendingNativePushEvents()
            return
        }

        Messaging.messaging().apnsToken = deviceToken
        fetchFCMRegistrationToken()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
        pendingFCMErrorMessage = error.localizedDescription
        flushPendingNativePushEvents()
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = normalizedToken(fcmToken) else {
            return
        }

        pendingFCMToken = token
        pendingFCMErrorMessage = nil
        flushPendingNativePushEvents()
    }

    private func fetchFCMRegistrationToken() {
        guard FirebaseApp.app() != nil else {
            return
        }

        Messaging.messaging().token { [weak self] token, error in
            guard let self else {
                return
            }

            if let error {
                self.pendingFCMErrorMessage = error.localizedDescription
                self.flushPendingNativePushEvents()
                return
            }

            guard let token = self.normalizedToken(token) else {
                return
            }

            self.pendingFCMToken = token
            self.pendingFCMErrorMessage = nil
            self.flushPendingNativePushEvents()
        }
    }

    private func firebaseOptions() -> FirebaseOptions? {
        guard let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let options = FirebaseOptions(contentsOfFile: filePath),
              firebaseOptionsLookValid(options) else {
            return nil
        }

        return options
    }

    private func firebaseOptionsLookValid(_ options: FirebaseOptions) -> Bool {
        let requiredValues = [
            options.googleAppID,
            options.gcmSenderID,
            options.projectID,
            options.apiKey
        ]

        return requiredValues.allSatisfy { value in
            guard let value else {
                return false
            }

            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmedValue.isEmpty && !trimmedValue.contains("REPLACE_ME")
        }
    }

    private func normalizedToken(_ token: String?) -> String? {
        guard let token else {
            return nil
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedToken.isEmpty ? nil : trimmedToken
    }

    private func flushPendingNativePushEvents() {
        guard let bridge = bridgeViewController()?.bridge else {
            return
        }

        if let token = pendingFCMToken,
           let payload = jsonPayload(["token": token, "provider": "fcm"]) {
            bridge.triggerWindowJSEvent(eventName: nativePushRegistrationEvent, data: payload)
            pendingFCMToken = nil
        }

        if let message = pendingFCMErrorMessage,
           let payload = jsonPayload(["message": message]) {
            bridge.triggerWindowJSEvent(eventName: nativePushRegistrationErrorEvent, data: payload)
            pendingFCMErrorMessage = nil
        }
    }

    private func bridgeViewController() -> CAPBridgeViewController? {
        if let bridgeViewController = window?.rootViewController as? CAPBridgeViewController {
            return bridgeViewController
        }

        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap(\.rootViewController)
            .compactMap { $0 as? CAPBridgeViewController }
            .first
    }

    private func jsonPayload(_ payload: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }

        return jsonString
    }

}
