import Foundation

/// 一次积分查询的结果与诊断信息
struct CreditProbe: Sendable {
    var total: Double? = nil
    var isPaid: Bool = false
    var packageCount: Int = 0
    /// 实际成功的 host+path（nil 表示全部失败）
    var endpoint: String? = nil
    /// 逐条尝试记录，用于界面展示拿不到积分的原因
    var attempts: [String] = []
    var ok: Bool { total != nil }
    var summary: String {
        if let total = total {
            let t = total == total.rounded() ? String(Int(total)) : String(format: "%.1f", total)
            return "剩余 \(t) 积分" + (isPaid ? " · 付费" : "")
        }
        return attempts.last ?? "查询失败"
    }
}

/// 上游业务：登录、刷新、模型目录、积分、签到、成长任务、活动。
@MainActor
final class Upstream {
    static let shared = Upstream()
    private let net = Net.shared
    private var store: AppStore { AppStore.shared }

    // MARK: - 登录

    struct LoginSession {
        var state: String
        var authURL: String
        var realm: Realm
    }

    func startLogin(realm: Realm) async throws -> LoginSession {
        let url = realm.chatBase + "/v2/plugin/auth/state?platform=CLI"
        let resp = try await net.send(url, method: "POST", headers: Wire.loginHeaders(realm: realm), body: Data("{}".utf8))
        guard let env = Net.envelope(resp), env.code == 0,
              let data = env.data as? [String: Any],
              let state = data["state"] as? String, let authURL = data["authUrl"] as? String else {
            throw Wire.UpstreamError(kind: .server, status: resp.status, message: "auth/state 返回异常: \(resp.text.prefix(200))")
        }
        return LoginSession(state: state, authURL: authURL, realm: realm)
    }

    enum PollResult {
        case pending
        case done(Account)
        case failed(String)
    }

    func pollLogin(_ session: LoginSession) async -> PollResult {
        let url = session.realm.chatBase + "/v2/plugin/auth/token?state=\(session.state)"
        guard let resp = try? await net.send(url, method: "GET", headers: Wire.loginHeaders(realm: session.realm)) else {
            return .pending
        }
        guard let env = Net.envelope(resp) else { return .pending }
        if env.code == 11217 { return .pending }
        if env.code != 0 { return .failed(env.msg.isEmpty ? "code=\(env.code)" : env.msg) }
        guard let data = env.data as? [String: Any],
              let access = data["accessToken"] as? String, !access.isEmpty else { return .pending }
        let refresh = data["refreshToken"] as? String ?? ""
        let expiresIn = (data["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let domain = data["domain"] as? String ?? ""
        var account = Account()
        account.realm = session.realm
        account.accessToken = access
        account.refreshToken = refresh
        account.domain = domain.isEmpty ? (session.realm == .global ? "www.workbuddy.ai" : "copilot.tencent.com") : domain
        account.expiresAt = expiresIn > 1_000_000_000 ? expiresIn : (expiresIn > 0 ? Date().timeIntervalSince1970 + expiresIn : 0)
        account.uid = Self.uidFromJWT(access)
        if let info = await fetchAccountInfo(session: session, access: access) {
            account.uid = info.uid.isEmpty ? account.uid : info.uid
            account.nickname = info.nickname
            account.enterpriseID = info.enterpriseID
        }
        if account.nickname.isEmpty { account.nickname = "账号 \(account.uid.prefix(6))" }
        return .done(account)
    }

    private func fetchAccountInfo(session: LoginSession, access: String) async -> (uid: String, nickname: String, enterpriseID: String)? {
        let url = session.realm.chatBase + "/v2/plugin/login/account?state=\(session.state)"
        var headers = Wire.loginHeaders(realm: session.realm)
        headers["Authorization"] = "Bearer \(access)"
        guard let resp = try? await net.send(url, method: "GET", headers: headers),
              let env = Net.envelope(resp), let data = env.data as? [String: Any] else { return nil }
        return ((data["uid"] as? String) ?? "",
                (data["nickname"] as? String) ?? "",
                (data["enterpriseId"] as? String) ?? "")
    }

    /// 从 AT 的 JWT payload 里取 uid（sub）。
    static func uidFromJWT(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (obj["sub"] as? String) ?? (obj["uid"] as? String) ?? ""
    }

    // MARK: - 刷新

    /// 刷新 AT/RT 并写回账号；失败抛错（调用方决定是否停用账号）。
    func refresh(_ account: Account) async throws -> Account {
        guard !account.refreshToken.isEmpty else {
            throw Wire.UpstreamError(kind: .sessionDead, status: 401, message: "无 refreshToken，需重新登录")
        }
        let url = account.realm.chatBase + "/v2/plugin/auth/token/refresh"
        let env = try await net.json(url, method: "POST", headers: Wire.refreshHeaders(account: account))
        guard let data = env.data as? [String: Any],
              let access = data["accessToken"] as? String, !access.isEmpty else {
            throw Wire.UpstreamError(kind: .sessionDead, status: 401, message: "refresh 未返回 accessToken，需重新登录")
        }
        var updated = account
        updated.accessToken = access
        if let rt = data["refreshToken"] as? String, !rt.isEmpty { updated.refreshToken = rt }
        if let domain = data["domain"] as? String, !domain.isEmpty { updated.domain = domain }
        let expiresIn = (data["expiresIn"] as? NSNumber)?.doubleValue ?? 0
        if expiresIn > 0 && expiresIn < 315_360_000 {
            updated.expiresAt = Date().timeIntervalSince1970 + expiresIn
        }
        return updated
    }

    /// 账本上的“保证可用账号”：过期则自动刷新并写回。
    func ensureFresh(_ account: Account) async -> Account {
        var current = account
        let now = Date().timeIntervalSince1970
        let needs = current.accessToken.isEmpty || (current.expiresAt > 0 && current.expiresAt - now < 600)
        guard needs else { return current }
        do {
            current = try await refresh(current)
            if let idx = store.accounts.firstIndex(where: { $0.id == current.id }) {
                store.accounts[idx] = current
                store.save()
            }
            store.log("已刷新凭证：\(current.displayName)", .ok)
        } catch {
            store.log("刷新失败 \(current.displayName)：\(error.localizedDescription)", .err)
        }
        return current
    }

    @discardableResult
    func refreshAll() async -> Int {
        var count = 0
        for account in store.activeAccounts {
            do {
                let updated = try await refresh(account)
                if let idx = store.accounts.firstIndex(where: { $0.id == account.id }) {
                    store.accounts[idx] = updated
                    count += 1
                }
            } catch {
                store.log("刷新失败 \(account.displayName)：\(error.localizedDescription)", .warn)
            }
        }
        store.save()
        store.log("凭证刷新完成：\(count)/\(store.activeAccounts.count)", count > 0 ? .ok : .warn)
        return count
    }

    /// 按 realm 取对应的上游覆盖地址。
    func baseOverride(for account: Account) -> String {
        account.realm == .global ? store.settings.globalBaseOverride : store.settings.cnBaseOverride
    }

    // MARK: - 模型目录

    /// 拉取模型目录；多域多前缀回退，全失败才用内置表。
    func fetchModels(account: Account) async -> [RemoteModel] {
        let fresh = await ensureFresh(account)
        let bases = Wire.growthBases(for: fresh, override: baseOverride(for: fresh))
        let paths = fresh.realm == .global
            ? ["/v2/enterprises/personal/models", "/console/enterprises/personal/models"]
            : ["/console/enterprises/personal/models", "/v2/enterprises/personal/models"]
        var headers = Wire.commonHeaders(realm: fresh.realm, uid: fresh.uid,
                                         domain: fresh.domain, enterpriseID: fresh.enterpriseID)
        headers["Authorization"] = "Bearer \(fresh.accessToken)"
        headers["X-User-Id"] = fresh.uid

        for base in bases {
            for path in paths {
                guard let resp = try? await net.send(base + path, method: "GET", headers: headers),
                      resp.status < 400, let env = Net.envelope(resp), env.code == 0,
                      let data = env.data as? [String: Any] else { continue }
                let models = Self.parseModels(data)
                if !models.isEmpty {
                    store.log("模型目录：\(models.count) 个（\(base)）", .info)
                    return models
                }
            }
        }
        store.log("模型目录拉取失败，使用内置表", .warn)
        return Self.staticModels
    }

    static func parseModels(_ data: [String: Any]) -> [RemoteModel] {
        let rows = (data["models"] as? [[String: Any]]) ?? []
        let cliIDs: Set<String> = {
            guard let agents = data["agents"] as? [[String: Any]],
                  let cli = agents.first(where: { ($0["name"] as? String) == "cli" }),
                  let ids = cli["models"] as? [String] else { return [] }
            return Set(ids)
        }()
        var models: [RemoteModel] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            if (row["disabled"] as? Bool) == true { continue }
            if !cliIDs.isEmpty, !cliIDs.contains(id) { continue }
            let input = (row["maxInputTokens"] as? NSNumber)?.intValue ?? 0
            let output = (row["maxOutputTokens"] as? NSNumber)?.intValue ?? 0
            if input <= 0 || output <= 0 { continue }
            if let tags = row["tags"] as? [String], tags.contains("text-to-image") { continue }
            if output <= 256 { continue }
            let reasoning = row["reasoning"] as? [String: Any]
            models.append(RemoteModel(
                id: id,
                name: (row["name"] as? String) ?? id,
                contextWindow: input,
                maxTokens: output,
                supportsImages: (row["supportsImages"] as? Bool) ?? false,
                credits: (row["credits"] as? String) ?? "",
                efforts: (reasoning?["supportedEfforts"] as? [String]) ?? [],
                description: (row["descriptionZh"] as? String) ?? ""
            ))
        }
        models.sort { $0.id < $1.id }
        return models
    }

    static let staticModels: [RemoteModel] = [
        ("glm-5.3", 1_000_000, 131_072), ("glm-5.2", 1_000_000, 131_072), ("glm-5.1", 200_000, 131_072),
        ("glm-5.3-flash", 1_000_000, 131_072), ("kimi-k3", 1_048_576, 131_072), ("kimi-k2.7", 256_000, 65_536),
        ("kimi-k2.6", 256_000, 262_144), ("kimi-k2.5", 164_000, 262_144), ("minimax-m3", 512_000, 512_000),
        ("hy4-preview", 1_000_000, 64_000), ("hy3", 192_000, 64_000), ("deepseek-v4.1-flash", 1_000_000, 384_000),
        ("deepseek-v4-pro", 1_000_000, 384_000), ("deepseek-v4-flash", 1_000_000, 384_000),
        ("gpt-5.6-sol", 1_050_000, 128_000), ("gpt-5.6-terra", 1_050_000, 128_000), ("gpt-5.5", 1_050_000, 128_000),
        ("gpt-5.3-codex", 400_000, 128_000), ("gemini-3.5-flash", 1_048_576, 65_536), ("auto", 168_000, 32_000),
    ].map { RemoteModel(id: $0.0, name: $0.0, contextWindow: $0.1, maxTokens: $0.2,
                        supportsImages: false, credits: "", efforts: [], description: "") }

    // MARK: - 积分 / 用量

    struct Credits {
        var total: Double
        var packages: [(name: String, remain: Double, total: Double, used: Double)]
        var isPaid: Bool

        var summary: String {
            guard !packages.isEmpty else { return "暂无套餐" }
            let detail = packages.map { "\($0.name) \(Self.num($0.remain))/\(Self.num($0.total))" }.joined(separator: "；")
            return "剩余 \(Self.num(total))（\(detail)）"
        }
        static func num(_ v: Double) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
    }

    /// 查询积分，返回完整诊断（失败时也能说明原因）
    func probeCredits(_ account: Account) async -> CreditProbe {
        var probe = CreditProbe()
        let fresh = await ensureFresh(account)
        let bases = Wire.billingBases(for: fresh, override: baseOverride(for: fresh))
        let headers = Wire.billingHeaders(account: fresh)

        let paths = [
            "/billing/meter/get-user-resource-summary",
            "/v2/billing/meter/get-user-resource-summary",
            "/billing/meter/get-user-resource",
            "/v2/billing/meter/get-user-resource",
        ]

        for path in paths {
            for base in bases {
                let host = URL(string: base)?.host ?? base
                let label = "\(host)\(path)"
                let resp: Net.Response
                do {
                    resp = try await net.send(base + path, method: "POST",
                                              headers: headers, body: Data("{}".utf8))
                } catch {
                    probe.attempts.append("\(label)：网络失败 \(error.localizedDescription)")
                    continue
                }
                if resp.status >= 400 {
                    probe.attempts.append("\(label)：HTTP \(resp.status)")
                    continue
                }
                guard let env = Net.envelope(resp) else {
                    probe.attempts.append("\(label)：响应不是 JSON")
                    continue
                }
                if env.code != 0 {
                    let msg = env.msg.isEmpty ? "code=\(env.code)" : env.msg
                    probe.attempts.append("\(label)：\(msg)")
                    continue
                }
                guard let data = env.data as? [String: Any] else {
                    probe.attempts.append("\(label)：data 为空")
                    continue
                }

                // 1) 标准 Packages 结构
                if let pkgs = data["Packages"] as? [[String: Any]], !pkgs.isEmpty {
                    var total = 0.0
                    for p in pkgs {
                        total += Self.number(p, ["CycleRemainCapacity", "remain_capacity",
                                                 "remainCapacity", "remain", "balance"])
                    }
                    probe.total = total
                    probe.packageCount = pkgs.count
                    probe.isPaid = (data["IsPaidUser"] as? Bool) ?? false
                    probe.endpoint = label
                    return probe
                }

                // 2) 扁平字段兜底（不同活动/版本字段名不一致）
                let flat = Self.number(data, ["remain_capacity", "remainCapacity", "remain",
                                              "credit", "credits", "balance", "total_credit",
                                              "totalCredit", "available"])
                if flat > 0 || data.keys.contains(where: { $0.lowercased().contains("credit") }) {
                    probe.total = flat
                    probe.packageCount = 0
                    probe.isPaid = (data["IsPaidUser"] as? Bool) ?? (data["is_paid_user"] as? Bool) ?? false
                    probe.endpoint = label
                    return probe
                }

                probe.attempts.append("\(label)：成功但无积分字段（keys: \(data.keys.sorted().prefix(6).joined(separator: ",")))")
            }
        }
        return probe
    }

    /// 兼容旧调用
    func credits(_ account: Account) async -> Credits? {
        let probe = await probeCredits(account)
        guard let total = probe.total else { return nil }
        var list: [(name: String, remain: Double, total: Double, used: Double)] = []
        if probe.packageCount > 0 {
            for i in 0..<probe.packageCount {
                list.append((name: i == 0 ? "主套餐" : "加量包\(i)", remain: 0, total: 0, used: 0))
            }
            list[0] = (name: "主套餐", remain: total, total: total, used: 0)
        } else {
            list = [(name: "主套餐", remain: total, total: total, used: 0)]
        }
        return Credits(total: total, packages: list, isPaid: probe.isPaid)
    }

    /// 宽松取数：字段名不确定时依次尝试，兼容数字与字符串
    nonisolated static func number(_ obj: [String: Any], _ keys: [String]) -> Double {
        for k in keys {
            if let n = obj[k] as? NSNumber { return n.doubleValue }
            if let d = obj[k] as? Double { return d }
            if let i = obj[k] as? Int { return Double(i) }
            if let str = obj[k] as? String, let d = Double(str) { return d }
        }
        return 0
    }

    func usage(_ account: Account) async -> String {
        let fresh = await ensureFresh(account)
        let bases = Wire.billingBases(for: fresh, override: baseOverride(for: fresh))
        let headers = Wire.billingHeaders(account: fresh)
        for path in ["/billing/meter/get-user-resource", "/v2/billing/meter/get-user-resource"] {
            for base in bases {
                guard let resp = try? await net.send(base + path, method: "POST", headers: headers,
                                                     body: Data("{}".utf8)),
                      resp.status < 400, let env = Net.envelope(resp), env.code == 0,
                      let data = env.data as? [String: Any],
                      let inner = (data["Response"] as? [String: Any])?["Data"] as? [String: Any] else { continue }
                let count = (inner["TotalCount"] as? NSNumber)?.intValue ?? 0
                let dosage = (inner["TotalDosage"] as? NSNumber)?.doubleValue ?? 0
                return "\(count) 类资源，本月已用 \(Credits.num(dosage)) 次"
            }
        }
        return "用量数据延迟 2-3 小时"
    }

    // MARK: - 让所有账号的积分刷新到界面

    func refreshCredits() async {
        for account in store.accounts {
            if let c = await credits(account) {
                if let idx = store.accounts.firstIndex(where: { $0.id == account.id }) {
                    store.accounts[idx].credits = c.total
                }
            }
        }
        store.save()
    }
}
