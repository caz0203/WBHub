import Foundation
import AVFoundation
import UIKit
import BackgroundTasks

/// iOS 真后台保活。
///
/// **为什么必须用音频**：iOS 只有三类进程能长期驻留后台 —— 音频、定位、VoIP。
/// BGTaskScheduler 与 beginBackgroundTask 都只是「续命」，系统随时回收，
/// 这也正是各类开源实现（以及所有后台常驻类 App）统一走静音音频的原因。
///
/// 本实现在「真后台」与「不影响正常用机」之间做了这些取舍：
///  · 会话 `.mixWithOthers`：**永不打断**用户的音乐 / 导航 / 通话，也不抢音频焦点
///  · 音量恒为 0，前台一律暂停（前台本来不需要保活）
///  · 省电档用 **8kHz 单声道 1 秒** 循环：解码器负担约为 44.1kHz 立体声的 1/11，
///    实测长时间运行无明显发热（这是官方 8k 语音档的下限）
///  · 低电量模式 / 温度 ≥ serious / 电量 < 20% 且未充电 → **立即暂停音频**，
///    改用 BGTask 续命，等环境恢复再自动接上
///  · 被来电、其他 App 打断后，在 interruption ended 时自动恢复
///  · 看门狗 60 秒一次，只在真的掉了才重启
@MainActor
final class KeepAlive: ObservableObject {
    static let shared = KeepAlive()

    static let keepAliveTaskID = "com.xiaoshuai.wbhub.keepalive"
    static let refreshTaskID = "com.xiaoshuai.wbhub.refresh"
    static let taskRunID = "com.xiaoshuai.wbhub.task"

    @Published private(set) var active = false
    @Published private(set) var detail = "未开启"
    @Published private(set) var degraded = false
    @Published private(set) var audioOn = false
    @Published private(set) var renewCount = 0
    /// 本次保活已持续秒数
    @Published private(set) var uptime: Int = 0

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var watchdog: Task<Void, Never>?
    private var wantsAlive = false
    private var mode: KeepAliveMode = .audioEco
    private var inForeground = true
    private var registered = false
    private var startedAt: Date?

    // MARK: - 启动

    func bootstrap() {
        guard !registered else { return }
        registered = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.keepAliveTaskID, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in
                KeepAlive.shared.renewCount += 1
                KeepAlive.shared.reassert()
                Self.scheduleKeepAlive()
                processing.setTaskCompleted(success: true)
            }
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in
                KeepAlive.shared.reassert()
                Self.scheduleRefresh()
                refresh.setTaskCompleted(success: true)
            }
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskRunID, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in
                await TaskRunner.shared.runFromUI(store: AppStore.shared)
                Self.scheduleDailyTask()
                processing.setTaskCompleted(success: true)
            }
        }
    }

    // MARK: - 开关

    func sync(enabled: Bool, mode: KeepAliveMode) {
        wantsAlive = enabled
        self.mode = mode
        if enabled {
            bootstrap()
            scheduleBackgroundWork()
            apply()
        } else {
            stop()
        }
    }

    /// 回前台：立刻停音频，不占音频通道
    func enterForeground() {
        inForeground = true
        guard wantsAlive else { return }
        pauseAudio()
        active = true
        degraded = false
        detail = "前台运行（保活待命）"
        scheduleBackgroundWork()
    }

    /// 切后台：真后台的重头戏
    func enterBackground() {
        inForeground = false
        guard wantsAlive else { return }
        scheduleBackgroundWork()
        apply()
    }

    func reassert() {
        guard wantsAlive else { return }
        if inForeground { active = true; return }
        apply()
    }

    // MARK: - 决策

    private func apply() {
        guard wantsAlive else { return }

        // 仅系统档：不碰音频
        guard mode.usesAudio else {
            pauseAudio()
            beginAssertion()
            startWatchdog()
            active = true
            degraded = false
            detail = "仅系统续期（不占音频）"
            return
        }

        if shouldDegrade() {
            pauseAudio()
            beginAssertion()
            startWatchdog()
            active = true
            degraded = true
            detail = degradeReason()
            return
        }

        degraded = false
        if inForeground {
            pauseAudio()
            active = true
            detail = "前台运行（保活待命）"
        } else {
            configureSession()
            installObservers()
            startPlayer()
            beginAssertion()
            startWatchdog()
        }
    }

    private func degradeReason() -> String {
        if UIDevice.current.isLowPowerModeEnabled { return "已降级：低电量模式，暂停音频" }
        let t = ProcessInfo.processInfo.thermalState
        if t == .serious || t == .critical { return "已降级：设备温度偏高，暂停音频" }
        return "已降级：电量偏低且未充电，暂停音频"
    }

    private func shouldDegrade() -> Bool {
        if UIDevice.current.isLowPowerModeEnabled { return true }
        let t = ProcessInfo.processInfo.thermalState
        if t == .serious || t == .critical { return true }
        let level = UIDevice.current.batteryLevel
        if level >= 0, level < 0.20, UIDevice.current.batteryState == .unplugged { return true }
        return false
    }

    // MARK: - 后台调度（辅助，不是主力）

    private func scheduleBackgroundWork() {
        Self.scheduleKeepAlive()
        Self.scheduleRefresh()
        Self.scheduleDailyTask()
    }

    static func scheduleKeepAlive() {
        let r = BGProcessingTaskRequest(identifier: keepAliveTaskID)
        r.requiresNetworkConnectivity = false
        r.requiresExternalPower = false
        r.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    static func scheduleDailyTask() {
        let r = BGProcessingTaskRequest(identifier: taskRunID)
        r.requiresNetworkConnectivity = true
        r.requiresExternalPower = false
        r.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }

    // MARK: - 音频

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：不打断用户正在播放的音乐/导航，也不抢焦点
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
    }

    private func startPlayer() {
        if player == nil {
            let rate = mode.sampleRate
            guard rate > 0, let data = Self.silentWAV(sampleRate: rate, seconds: 1) else {
                active = false
                detail = "静音音频生成失败"
                return
            }
            do {
                let p = try AVAudioPlayer(data: data)
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                player = p
            } catch {
                active = false
                detail = "播放器初始化失败"
                return
            }
        }
        guard let player = player else { return }
        if !player.isPlaying {
            let ok = player.play()
            active = ok
            audioOn = ok
            if ok, startedAt == nil { startedAt = Date() }
            detail = ok ? "真后台运行中（\(mode.label)）" : "播放启动失败"
        } else {
            active = true
            audioOn = true
        }
    }

    private func pauseAudio() {
        player?.stop()
        player = nil
        audioOn = false
        startedAt = nil
        uptime = 0
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func stop() {
        pauseAudio()
        watchdog?.cancel()
        watchdog = nil
        endAssertion()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.keepAliveTaskID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        active = false
        degraded = false
        detail = "未开启"
    }

    // MARK: - 中断恢复

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self = self, self.wantsAlive, !self.inForeground else { return }
                    guard self.mode.usesAudio else { return }
                    if name == AVAudioSession.interruptionNotification {
                        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                        guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                    }
                    self.player = nil
                    self.configureSession()
                    self.startPlayer()
                }
            }
            observers.append(token)
        }
    }

    // MARK: - 后台断言

    private func beginAssertion() {
        endAssertion()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "WBHub.KeepAlive") { [weak self] in
            Task { @MainActor in self?.endAssertion() }
        }
    }

    private func endAssertion() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - 看门狗

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self = self, self.wantsAlive else { return }
                if self.inForeground { continue }

                if let start = self.startedAt {
                    self.uptime = Int(Date().timeIntervalSince(start))
                }

                // 环境恶化立刻让路给系统与用户
                if self.mode.usesAudio, self.shouldDegrade() {
                    if self.player != nil {
                        self.pauseAudio()
                        self.degraded = true
                        self.detail = self.degradeReason()
                    }
                    self.beginAssertion()
                    continue
                }
                if self.mode.usesAudio, self.player?.isPlaying != true {
                    self.degraded = false
                    try? AVAudioSession.sharedInstance().setActive(true, options: [])
                    self.startPlayer()
                    self.beginAssertion()
                }
                self.scheduleBackgroundWork()
            }
        }
    }

    // MARK: - 静音 WAV

    private static func silentWAV(sampleRate: Int, seconds: Int) -> Data? {
        let channels = 1
        let bits = 16
        let frames = sampleRate * seconds
        let dataBytes = frames * channels * bits / 8

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }

        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16)
        u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bits / 8))
        u16(UInt16(channels * bits / 8))
        u16(UInt16(bits))
        str("data"); u32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))
        return d
    }
}

// MARK: - 定时调度

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
                let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
                let day = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
                let hour = c.hour ?? 0
                let minute = c.minute ?? 0

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
