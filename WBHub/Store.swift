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
    }

    init() { load() }

    // MARK: - persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        accounts = p.accounts
        var s = p.settings
        if s.apiKey.isEmpty { s.apiKey = "sk-" + Hashing.randomHex(12) }
        settings = s
    }

    func save() {
        let snapshot = Persisted(accounts: accounts, settings: settings)
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

    // MARK: - accounts

    func upsert(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
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
}
