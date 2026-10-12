import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must happen at launch: a VoIP push can start the app in the background.
        CallKitManager.shared.start()
        return true
    }
}

@main
struct KidsCallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(appState.callManager)
                .onOpenURL { url in appState.handleOpenURL(url) }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active: appState.connectIfRegistered()
                    case .background: appState.disconnectIfIdle()
                    default: break
                    }
                }
        }
    }
}
