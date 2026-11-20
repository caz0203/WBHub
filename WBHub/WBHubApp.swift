import SwiftUI
import AVFoundation

@main
@MainActor
struct WBHubApp: App {
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    Task { @MainActor in
                        await ServerManager.shared.reloadModels()
                        await store.refreshCreditsAsync()
                        if store.settings.autoTask { Scheduler.shared.start(store: store) }
                        KeepAlive.shared.sync(enabled: store.settings.backgroundKeepAlive)
                    }
                }
        }
    }
}

/// 后台保活：静音音频会话让监听在切后台后尽量存活（巨魔 / 越狱环境更稳）。
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()
    private var token: Any?

    func sync(enabled: Bool) {
        if enabled {
            guard token == nil else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            token = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { _ in }
        } else {
            if let existing = token { NotificationCenter.default.removeObserver(existing) }
            token = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}

/// 极简定时器调度：每日任务 + 夜间窗口，App 存活时生效。
@MainActor
final class Scheduler {
    static let shared = Scheduler()
    private var task: Task<Void, Never>?
    private var lastRunDay = ""
    private var lastNightDay = ""

    func start(store: AppStore) {
        task?.cancel()
        task = Task { [weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let store = store else { return }
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
                let day = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
                let hour = comps.hour ?? 0
                let minute = comps.minute ?? 0

                if store.settings.autoTask, day != self.lastRunDay,
                   hour == store.settings.taskHour, minute == store.settings.taskMinute {
                    self.lastRunDay = day
                    store.log("定时任务触发", .info)
                    await TaskRunner.shared.runFromUI(store: store)
                }
                if store.settings.nightTask, day != self.lastNightDay, hour == 23, minute == 5 {
                    self.lastNightDay = day
                    store.log("夜间窗口任务触发", .info)
                    let r = await TaskRunner.shared.runNightWindow()
                    store.currentTasks.append(contentsOf: r.steps)
                }
            }
        }
    }
}
