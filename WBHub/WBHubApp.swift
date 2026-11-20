import SwiftUI

@main
struct WBHubApp: App {
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    KeepAlive.shared.bootstrap()
                    KeepAlive.shared.sync(enabled: store.settings.backgroundKeepAlive,
                                          mode: store.settings.keepAliveMode)
                    Scheduler.shared.start(store: store)
                }
        }
    }
}
