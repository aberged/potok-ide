import Capacitor
import UIKit

/// The app's Capacitor view controller (Main.storyboard): registers the
/// plugins that live in the app itself rather than in a package.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(ShareInboxPlugin())
    }
}
