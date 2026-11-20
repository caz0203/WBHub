import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var accounts: [Account] = []
    @Published var settings: Settings = Settings()
    @Published var logs: [LogLine] = []
    @Published var models: [RemoteModel] = []
    @Published var serverRunning = false
    @Published var currentTasks: [TaskStep] = []
    @Published var taskRunning = false
    @Published var requestCount = 0
    @Published var lastError: String = ""
    @Published var requestLogs: [RequestLog] = []
    /// 每个账号最近一次积分查询的诊断（key = account.id.uuidString）
    @Published var creditProbes: [String: CreditProbe] = [:]

    private let io = DispatchQueue(label: "wbhub.store")
    private var saveWork: DispatchWorkItem?
    private var fileURL: URL { Self.dir.appendingPathComponent("store.json") }
    private static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private struct Persisted: Codable {
        var accounts: [Account]
        var settings: Settings
        var requestLogs: [RequestLog]?
    }

    init() { load() }

    // MARK: - persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        accounts = p.accounts
        requestLogs = p.requestLogs ?? []
        var s = p.settings
        if s.apiKey.isEmpty { s.apiKey = "sk-" + Hashing.randomHex(12) }
        settings = s
    }

    func save() {
        let snapshot = Persisted(accounts: accounts, settings: settings, requestLogs: requestLogs)
        let url = fileURL
        saveWork?.cancel()
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWork = work
        io.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - logs

    nonisolated func logFromAnyThread(_ text: String, _ level: LogLine.Level = .info) {
        Task { @MainActor in AppStore.shared.log(text, level) }
    }

    func log(_ text: String, _ level: LogLine.Level = .info) {
        let line = LogLine(level: level, text: text)
        logs.append(line)
        if logs.count > 600 { logs.removeFirst(logs.count - 600) }
        print("[\(line.level.rawValue)] \(text)")
    }

    func clearLogs() { logs.removeAll() }

    // MARK: - 请求日志

    /// 追加一条请求记录；超过上限时丢最旧的
    func addRequestLog(_ log: RequestLog) {
        requestLogs.insert(log, at: 0)
        if requestLogs.count > 300 {
            requestLogs.removeLast(requestLogs.count - 300)
        }
        save()
    }

    func clearRequestLogs() {
        requestLogs.removeAll()
        save()
    }

    /// 汇总：请求数、tokens、失败数
    func requestSummary() -> (count: Int, tokens: Int, failed: Int, avgMs: Int) {
        let count = requestLogs.count
        let tokens = requestLogs.reduce(0) { $0 + $1.totalTokens }
        let failed = requestLogs.filter { !$0.ok }.count
        let okLogs = requestLogs.filter { $0.ok && $0.elapsedMs > 0 }
        let avg = okLogs.isEmpty ? 0 : okLogs.reduce(0) { $0 + $1.elapsedMs } / okLogs.count
        return (count, tokens, failed, avg)
    }

    // MARK: - accounts

    func upsert(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    /// 就地修改某个账号
    func update(_ account: Account, _ mutate: (inout Account) -> Void) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        mutate(&accounts[idx])
        save()
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        save()
    }

    func account(for realm: Realm, index: Int) -> Account? {
        let pool = accounts.filter { $0.realm == realm && !$0.disabled }
        guard !pool.isEmpty else { return nil }
        return pool[index % pool.count]
    }

    var activeAccounts: [Account] { accounts.filter { !$0.disabled } }

    // MARK: - settings

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
        save()
    }

    var baseURL: String { "http://127.0.0.1:\(settings.port)/v1" }

    /// 局域网地址：同 Wi-Fi 下的手机/电脑用这个 Base URL
    var lanBaseURL: String? {
        guard let ip = LanIP.current() else { return nil }
        return "http://\(ip):\(settings.port)/v1"
    }

    /// 进入设置页或回前台时刷新一次
    func refreshLanIP() { LanIP.refresh() }

    func snapshotHeader() -> String {
        let pool = activeAccounts
        let cn = pool.filter { $0.realm == .cn }.count
        let gl = pool.filter { $0.realm == .global }.count
        return "\(pool.count) 账号（国内 \(cn) / 国际 \(gl)）"
    }
}

extension AppStore {
    func refreshCreditsAsync() async {
        await Upstream.shared.refreshCredits()
    }

    /// 刷新全部账号积分，同时保留每次查询的诊断信息
    @discardableResult
    func refreshCreditsWithDiagnostics() async -> (ok: Int, failed: Int, gained: Double) {
        var ok = 0, failed = 0
        var gained = 0.0
        for account in accounts {
            let before = account.credits
            let probe = await Upstream.shared.probeCredits(account)
            creditProbes[account.id.uuidString] = probe
            guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { continue }
            if let total = probe.total {
                accounts[idx].credits = total
                if total > before { gained += total - before }
                ok += 1
            } else {
                failed += 1
            }
        }
        save()
        return (ok, failed, gained)
    }
}
