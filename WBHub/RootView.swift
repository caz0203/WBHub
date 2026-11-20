import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .home

    enum Tab: String, CaseIterable {
        case home = "首页"
        case tasks = "任务"
        case prompt = "提示词"
        case accounts = "账号"
        case settings = "设置"
        var icon: String {
            switch self {
            case .home: return "bolt.horizontal.circle"
            case .tasks: return "checklist"
            case .prompt: return "text.badge.checkmark"
            case .accounts: return "person.2.circle"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label(Tab.home.rawValue, systemImage: Tab.home.icon) }.tag(Tab.home)
            TasksView().tabItem { Label(Tab.tasks.rawValue, systemImage: Tab.tasks.icon) }.tag(Tab.tasks)
            PromptView().tabItem { Label(Tab.prompt.rawValue, systemImage: Tab.prompt.icon) }.tag(Tab.prompt)
            AccountsView().tabItem { Label(Tab.accounts.rawValue, systemImage: Tab.accounts.icon) }.tag(Tab.accounts)
            SettingsView().tabItem { Label(Tab.settings.rawValue, systemImage: Tab.settings.icon) }.tag(Tab.settings)
        }
        .tint(Theme.accent)
        .onAppear {
            if store.settings.autoStart && !store.serverRunning {
                Task { @MainActor in await ServerManager.shared.start() }
            }
        }
        .onChange(of: scenePhase) { phase in
            // 回到前台时确保反代还活着（系统可能回收了监听）
            if phase == .active, store.settings.autoStart, !store.serverRunning {
                Task { @MainActor in await ServerManager.shared.start() }
            }
        }
    }
}
