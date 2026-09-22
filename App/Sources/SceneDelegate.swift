import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let navigation = UINavigationController(rootViewController: LedgerListViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-debug-open") {
            let debug = DebugViewController()
            navigation.pushViewController(debug, animated: false)
            if arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") {
                debug.open(arguments[index + 1])
            }
        }
        #endif
    }
}
