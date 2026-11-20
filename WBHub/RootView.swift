import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .home

    enum Tab: String, CaseIterable {
        case home = "首页"
        case tasks = "任务"
        case models = "模型"
        case accounts = "账号"
        case settings = "设置"

        var icon: String {
            switch self {
            case .home: return "bolt.horizontal.circle"
            case .tasks: return "checklist"
            case .models: return "cube.transparent"
            case .accounts: return "person.2.circle"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label(Tab.home.rawValue, systemImage: Tab.home.icon) }.tag(Tab.home)
            TasksView().tabItem { Label(Tab.tasks.rawValue, systemImage: Tab.tasks.icon) }.tag(Tab.tasks)
            ModelsView().tabItem { Label(Tab.models.rawValue, systemImage: Tab.models.icon) }.tag(Tab.models)
            AccountsView().tabItem { Label(Tab.accounts.rawValue, systemImage: Tab.accounts.icon) }.tag(Tab.accounts)
            SettingsView().tabItem { Label(Tab.settings.rawValue, systemImage: Tab.settings.icon) }.tag(Tab.settings)
        }
        .tint(Theme.accent)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if store.settings.autoStart && !store.serverRunning {
                    Task { @MainActor in await ServerManager.shared.start() }
                }
                KeepAlive.shared.enterForeground()
                store.refreshLanIP()
            case .background:
                KeepAlive.shared.enterBackground()
            default:
                break
            }
        }
    }
}
