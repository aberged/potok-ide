import Capacitor
import UIKit

/// The app's Capacitor view controller (Main.storyboard): registers the
/// plugins that live in the app itself rather than in a package.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(ShareInboxPlugin())
        // iOS has no back button: a swipe from the left edge goes back, as in
        // Safari. Capacitor leaves it off and has no setting for it. Android's
        // back button is handled in app.js (registerCapacitorBackButton).
        webView?.allowsBackForwardNavigationGestures = true
    }
}
