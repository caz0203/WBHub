import Foundation

/// 一键跑完：签到 → 活跃上报 → 桌面事件 → 补签 → 礼包补偿 → 成长任务 → 连登兑换 → 抽奖 → 猫猫旅行。
@MainActor
final class TaskRunner {
    static let shared = TaskRunner()
    private let net = Net.shared
    private var store: AppStore { AppStore.shared }
    private var up: Upstream { Upstream.shared }

    struct RunResult {
        var steps: [TaskStep] = []
        var creditEarned: Double = 0
        var okCount: Int { steps.filter(\.ok).count }
        var summary: String {
            steps.isEmpty ? "无可执行项" : steps.map { ($0.ok ? "✅ " : "• ") + $0.message }.joined(separator: "\n")
        }
    }

    // MARK: - 多主机请求（官方域历史上互为备份）

    private func request(_ bases: [String], path: String, method: String = "POST",
                         headers: [String: String], body: Any? = nil) async throws -> Net.Envelope {
        var lastError: Error?
        for base in bases {
            do {
                return try await net.json(base + path, method: method, headers: headers, body: body)
            } catch let error as Wire.UpstreamError {
                lastError = error
                // 只有「路径/主机不存在」才换域，业务错误直接回给调用方
                if error.kind == .transport || error.kind == .notFound
                    || error.status == 403 || error.status == 405 {
                    continue
                }
                throw error
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? (Wire.UpstreamError(kind: .transport, status: 0, message: "全部上游域不可达") as Error)
    }

    private func growth(_ account: Account, _ path: String, method: String = "POST",
                        body: Any? = nil) async throws -> Net.Envelope {
        try await request(Wire.growthBases(for: account, override: up.baseOverride(for: account)),
                          path: path, method: method,
                          headers: Wire.growthHeaders(account: account), body: body)
    }

    private func meter(_ account: Account, _ path: String, method: String = "POST",
                       body: Any? = nil) async throws -> Net.Envelope {
        try await request(Wire.billingBases(for: account, override: up.baseOverride(for: account)),
                          path: path, method: method,
                          headers: Wire.billingHeaders(account: account), body: body)
    }

    private func report(_ account: Account, _ events: [[String: Any]], mp: Bool = false) async throws {
        var headers = mp ? Wire.mpReportHeaders : Wire.billingHeaders(account: account)
        headers["Authorization"] = "Bearer \(account.accessToken)"
        headers["X-User-Id"] = account.uid
        _ = try await request(Wire.billingBases(for: account, override: up.baseOverride(for: account)),
                              path: "/v2/report", headers: headers, body: events)
    }

    // MARK: - 入口

    func runAll(night: Bool = false) async -> RunResult {
        var results = RunResult()
        let accounts = store.activeAccounts
        guard !accounts.isEmpty else {
            results.steps.append(TaskStep(label: "账号", ok: false, message: "没有可用账号，请先在「账号」页登录"))
            return results
        }
        for account in accounts {
            let fresh = await up.ensureFresh(account)
            store.log("开始跑任务：\(fresh.displayName)", .info)
            let r = await runOne(fresh, night: night)
            results.steps.append(contentsOf: r.steps)
            results.creditEarned += r.creditEarned
            if let idx = store.accounts.firstIndex(where: { $0.id == fresh.id }) {
                store.accounts[idx].lastRun = Self.stamp()
                store.accounts[idx].lastCheckin = Self.dayKey()
                if let c = await up.credits(fresh) {
                    store.accounts[idx].credits = c.total
                }
            }
        }
        store.save()
        store.log("任务完成：成功 \(results.okCount)/\(results.steps.count)，共 +\(Int(results.creditEarned)) 积分",
                  results.okCount > 0 ? .ok : .warn)
        return results
    }

    func runOne(_ account: Account, night: Bool) async -> RunResult {
        var out = RunResult()
        guard account.realm == .cn else {
            out.steps.append(TaskStep(label: "region", ok: false, message: "\(account.displayName)：国际版账号无成长中心任务，可正常反代"))
            return out
        }
        out.steps.append(await checkin(account))
        out.steps.append(await reportActivity(account))
        out.steps.append(await reportDesktopChain(account))
        if let make = await useMakeupCard(account) { out.steps.append(make) }
        out.steps.append(await claimOneOff(account))
        let growthRun = await runGrowthTasks(account, night: night)
        out.steps.append(contentsOf: growthRun.steps)
        out.creditEarned += growthRun.creditEarned
        let streakRun = await runStreak(account)
        out.steps.append(contentsOf: streakRun.steps)
        out.creditEarned += streakRun.creditEarned
        out.steps.append(contentsOf: await travel(account))
        let campaignRun = await runCampaigns(account)
        out.steps.append(contentsOf: campaignRun.steps)
        out.creditEarned += campaignRun.creditEarned
        return out
    }

    // MARK: - 签到

    func checkin(_ account: Account) async -> TaskStep {
        var activity: [String: Any] = [:]
        if let env = try? await meter(account, "/v2/billing/meter/checkin-activity-status", body: [String: Any]()),
           let data = env.data as? [String: Any] {
            activity = data
        } else if let env = try? await meter(account, "/billing/meter/checkin-activity-status", body: [String: Any]()),
                  let data = env.data as? [String: Any] {
            activity = data
        }
        if (activity["active"] as? Bool) == false {
            return TaskStep(label: "checkin", ok: false, message: "\(account.displayName)：签到活动已结束")
        }
        let streak = (activity["streak_days"] as? NSNumber)?.intValue ?? 0
        if (activity["today_checked_in"] as? Bool) == true {
            return TaskStep(label: "checkin", ok: true, message: "\(account.displayName)：今日已签到（连签 \(streak) 天）")
        }
        do {
            var env: Net.Envelope
            do {
                env = try await meter(account, "/v2/billing/meter/daily-checkin", body: [String: Any]())
            } catch {
                env = try await meter(account, "/billing/meter/daily-checkin", body: [String: Any]())
            }
            let data = (env.data as? [String: Any]) ?? [:]
            let credit = (data["credit"] as? NSNumber)?.doubleValue
                ?? (data["today_credit"] as? NSNumber)?.doubleValue ?? 0
            if env.code != 0 {
                let message = env.msg.isEmpty ? "code=\(env.code)" : env.msg
                if message.contains("already") || message.contains("已签到") || message.contains("已签") {
                    return TaskStep(label: "checkin", ok: true, message: "\(account.displayName)：今日已签到")
                }
                return TaskStep(label: "checkin", ok: false, message: "\(account.displayName)：签到失败 \(message)")
            }
            return TaskStep(label: "checkin", ok: true,
                            message: credit > 0 ? "\(account.displayName)：签到 +\(Int(credit)) 积分（连签 \(streak + 1) 天）"
                                                : "\(account.displayName)：签到成功（连签 \(streak + 1) 天）")
        } catch {
            let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
            return TaskStep(label: "checkin", ok: false, message: "\(account.displayName)：签到失败 \(message)")
        }
    }

    // MARK: - 活跃上报

    func reportActivity(_ account: Account) async -> TaskStep {
        let conv = Hashing.uuidFrom("wbhub-activity-\(account.uid)-\(Self.dayKey())")
        let req = Hashing.requestID()
        let model = store.settings.defaultModel == "auto" ? "deepseek-v4-flash" : store.settings.defaultModel
        let event = desktopEvent(account: account, code: "chat_request_send",
                                 conversation: conv, request: req, modelID: model)
        do {
            try await report(account, [desktopFingerprint(account: account).merging(event) { _, b in b }])
            return TaskStep(label: "activity", ok: true, message: "\(account.displayName)：今日活跃已上报")
        } catch {
            let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
            return TaskStep(label: "activity", ok: false, message: "\(account.displayName)：活跃上报失败 \(message)")
        }
    }

    /// 6 连桌面事件链，点亮「桌面端对话」。
    func reportDesktopChain(_ account: Account) async -> TaskStep {
        let conv = Hashing.conversationID()
        let req = Hashing.requestID()
        let msg = Hashing.requestID()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let model = "fast-model"
        let events: [[String: Any]] = [
            ["eventCode": "agent_task_created", "source": "LOCAL", "name": "working", "task_target": "local",
             "mode": "craft", "requestModelId": model, "requestModelName": model, "has_repo": false,
             "repo_type": "none", "workspace_type": "empty", "has_connector": false, "connector_types": [String](),
             "has_mention": false, "mention_types": [String](), "has_template": false, "action": "", "template_name": "",
             "has_expert": false, "expert_id": "", "expert_name": "", "expert_industry_id": "",
             "has_skill": false, "skill_names": [String](), "conversationId": conv, "messageId": msg,
             "buddyId": "", "buddyName": ""],
            ["eventCode": "chat_message_send", "messageId": msg + "-assistant", "historyCount": 0,
             "isContextTruncated": false, "currentStepCount": 1, "traceId": req, "rootRequestId": req,
             "parentConversationId": conv, "agentName": "cli", "agentType": "main"],
            desktopEvent(account: account, code: "chat_request_send", conversation: conv, request: req, modelID: model),
            ["eventCode": "chat_message_response", "messageId": msg + "-assistant", "responseModelId": model,
             "inputToken": 120, "outputToken": 80, "totalToken": 200, "cachedTokens": 0,
             "cachedWriteTokens": 0, "cachedMissTokens": 0, "isSuccessful": true, "messageErrorCode": "",
             "finishReason": "stop", "firstTokenAt": now, "traceId": req, "conversationId": conv,
             "rootRequestId": req, "parentConversationId": conv, "agentName": "cli", "agentType": "main"],
            ["eventCode": "chat_message_status", "messageId": msg + "-assistant", "messageErrorCode": "0",
             "traceId": req, "rootRequestId": req, "parentConversationId": conv, "agentName": "cli",
             "agentType": "main"],
            ["eventCode": "chat_request_response", "mode": "craft", "toolCallCount": 0, "inputToken": 120,
             "outputToken": 80, "totalToken": 200, "cachedTokens": 0, "cachedWriteTokens": 0,
             "cachedMissTokens": 0, "isSuccessful": true, "messageErrorCode": "", "finishReason": "stop",
             "rootRequestId": req, "parentConversationId": conv, "agentName": "cli", "agentType": "main"],
        ]
        let wrapped = events.map { desktopFingerprint(account: account).merging($0) { _, b in b } }
        do {
            try await report(account, wrapped)
            return TaskStep(label: "desktop", ok: true, message: "\(account.displayName)：桌面端对话事件已上报")
        } catch {
            let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
            return TaskStep(label: "desktop", ok: false, message: "\(account.displayName)：桌面事件上报失败 \(message)")
        }
    }

    // MARK: - 成长任务

    func runGrowthTasks(_ account: Account, night: Bool) async -> RunResult {
        var out = RunResult()
        guard let env = try? await growth(account, "/v2/activity/growth/tasks", method: "GET"),
              let data = env.data as? [String: Any],
              let rows = data["tasks"] as? [[String: Any]] else {
            // 老版本接口没有 /v2 前缀
            if let env2 = try? await growth(account, "/activity/growth/tasks", method: "GET"),
               let d2 = env2.data as? [String: Any], let r2 = d2["tasks"] as? [[String: Any]] {
                return await handleTaskRows(account, rows: r2, into: out)
            }
            out.steps.append(TaskStep(label: "tasks", ok: false, message: "\(account.displayName)：任务列表读取失败"))
            return out
        }
        return await handleTaskRows(account, rows: rows, into: out)
    }

    private func handleTaskRows(_ account: Account, rows: [[String: Any]], into seed: RunResult) async -> RunResult {
        var out = seed
        var todo: [String] = []
        var claimable: [String] = []
        for row in rows {
            guard let code = (row["task_code"] as? String) ?? (row["code"] as? String), !code.isEmpty else { continue }
            let progress = row["progress"] as? [String: Any]
            let current = (progress?["current"] as? NSNumber)?.intValue ?? (row["current"] as? NSNumber)?.intValue ?? 0
            let target = (progress?["target"] as? NSNumber)?.intValue ?? (row["target"] as? NSNumber)?.intValue ?? 0
            let status = ((row["accept_status"] as? String) ?? (row["status"] as? String) ?? "").lowercased()
            if status == "claimed" || status == "completed" || (row["claimed"] as? Bool) == true { continue }
            if target > 0 && current >= target { claimable.append(code) }
            else if status.isEmpty || status == "available" || status == "unaccepted" || status == "accepted" {
                todo.append(code)
            }
        }

        if !todo.isEmpty {
            do {
                let accept = try await growth(account, "/v2/activity/growth/tasks/accept",
                                               body: ["task_codes": todo])
                let results = ((accept.data as? [String: Any])?["results"] as? [[String: Any]]) ?? []
                let settled = results.filter { (($0["status"] as? String) ?? "") == "accepted" }.count
                out.steps.append(TaskStep(label: "accept", ok: true,
                                          message: "\(account.displayName)：接受任务 \(todo.count) 项（已结算 \(settled)）"))
            } catch {
                let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
                out.steps.append(TaskStep(label: "accept", ok: false, message: "\(account.displayName)：接受任务失败 \(message)"))
            }
            out.steps.append(await reportMpEvents(account))
            // 回读推进度后的可领奖
            if let again = try? await growth(account, "/v2/activity/growth/tasks", method: "GET"),
               let d2 = again.data as? [String: Any], let rows2 = d2["tasks"] as? [[String: Any]] {
                for row in rows2 {
                    guard let code = (row["task_code"] as? String) ?? (row["code"] as? String) else { continue }
                    let progress = row["progress"] as? [String: Any]
                    let current = (progress?["current"] as? NSNumber)?.intValue ?? 0
                    let target = (progress?["target"] as? NSNumber)?.intValue ?? 0
                    let status = ((row["accept_status"] as? String) ?? "").lowercased()
                    if status != "claimed", target > 0, current >= target, !claimable.contains(code) {
                        claimable.append(code)
                    }
                }
            }
        }

        for code in claimable {
            let (ok, credit, message) = await claimTask(account, code: code)
            if ok { out.creditEarned += credit }
            out.steps.append(TaskStep(label: code, ok: ok, message: message))
        }
        if claimable.isEmpty && todo.isEmpty {
            out.steps.append(TaskStep(label: "tasks", ok: true, message: "\(account.displayName)：成长任务无可结算项"))
        }
        return out
    }

    /// 任务动作的事件推进：小程序的对话 / 专家 / 灵感埋点。
    func reportMpEvents(_ account: Account) async -> TaskStep {
        let conv = Hashing.conversationID()
        let rid = Hashing.requestID()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let baseEvent: [String: Any] = [
            "timestamp": now, "reportDelay": 0, "ideType": "WorkBuddy_MP", "ideVersion": "2.4.0",
            "extName": "workbuddy-mp", "extVersion": "2.4.0", "product": "SaaS",
            "ideName": "wx_app_cloud", "platform": "mini_program", "source": "mini_program",
            "os": "android", "osVersion": "14", "arch": "arm64", "timezone": "Asia/Shanghai",
            "machineId": Hashing.uuidFrom("mp:\(account.uid)"), "userId": account.uid,
            "userNickname": account.nickname,
        ]
        func chat(_ model: String?, _ name: String?) -> [String: Any] {
            var e: [String: Any] = [
                "eventCode": "chat_request_send", "mode": "chat", "inputLength": 12, "isPlan": false,
                "isAutoExecuteTerminal": false, "isAutoModify": false, "codebaseEnable": false,
                "maxToken": 0, "maxSteps": 500, "temperature": 0, "maxRetries": 0,
                "mentionContexts": [String](), "knowledgeId": [String](), "knowledgeName": [String](),
                "codebaseId": "", "mentionContextCount": 0, "command": "", "recommendId": "", "skillId": "",
                "skillCount": 0, "totalCount": 0, "requestId": rid, "traceId": rid, "rootRequestId": rid,
                "parentConversationId": conv, "conversationId": conv, "messageId": "msg-" + String(rid.suffix(8)),
                "agentName": "mp", "agentType": "main",
                "codebuddy.session_id": conv, "codebuddy.conversation_request_id": rid,
            ]
            if let model = model { e["requestModelId"] = model }
            if let name = name { e["requestModelName"] = name }
            return e
        }
        let playbook: [String: Any] = [
            "eventCode": "playbook_cta_click", "id": "01-ProductDesign", "name": "产品设计",
            "type": "document", "categoryId": "", "categoryName": "", "skills": "", "skillNames": "",
            "source": "discover", "position": 1, "extVersion": "2.2.8",
        ]
        let expert: [String: Any] = [
            "eventCode": "expert_actual_use", "timestamp": now, "reportDelay": 0,
            "ideName": "wx_app_cloud", "ideType": "WorkBuddy_MP", "extName": "workbuddy-mp",
            "extVersion": "2.2.8", "product": "SaaS", "source": "mini_program", "os": "android",
            "osVersion": "14", "arch": "arm64", "timezone": "Asia/Shanghai",
            "machineId": Hashing.uuidFrom("mp:\(account.uid)"), "userId": account.uid,
            "id": "ex_GDl31WahyIH0", "name": "ex_GDl31WahyIH0", "expertTitle": "中国电商运营专家",
            "type": "send_message", "characterCount": 12, "expertType": "agent",
        ]
        let events = [chat(nil, nil), chat(nil, nil), chat("glm-5.2", "GLM-5.2"), playbook, expert]
            .map { baseEvent.merging($0) { _, b in b } }
        do {
            try await report(account, events, mp: true)
            return TaskStep(label: "mp-events", ok: true, message: "\(account.displayName)：任务事件已上报")
        } catch {
            let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
            return TaskStep(label: "mp-events", ok: false, message: "\(account.displayName)：任务事件上报失败 \(message)")
        }
    }

    /// 领奖：多域多前缀回退 + 回执/文案确认。
    func claimTask(_ account: Account, code: String) async -> (Bool, Double, String) {
        let bases = Wire.growthBases(for: account, override: up.baseOverride(for: account))
        let paths = [
            "/activity/growth/tasks/\(code)/claim",
            "/v2/activity/growth/tasks/\(code)/claim",
        ]
        let headers = Wire.growthHeaders(account: account)
        var best: Net.Envelope?
        var lastError: Error?
        let webHeaders: [String: String] = {
            var h = headers
            h["x-client-platform"] = "web"
            return h
        }()
        outer: for path in paths {
            for base in bases {
                for candidate in [headers, webHeaders] {
                    do {
                        let env = try await net.json(base + path, headers: candidate, body: [String: Any]())
                        best = env
                        if env.code == 0 { break outer }
                    } catch {
                        lastError = error
                    }
                }
            }
        }
        guard let env = best else {
            let message = (lastError as? Wire.UpstreamError)?.message ?? lastError?.localizedDescription ?? "领奖无响应"
            return (false, 0, "\(code)：\(message)")
        }
        let data = (env.data as? [String: Any]) ?? [:]
        let credit = (data["credit"] as? NSNumber)?.doubleValue
            ?? (data["reward_credit"] as? NSNumber)?.doubleValue ?? 0
        let energy = (data["energy"] as? NSNumber)?.doubleValue
            ?? (data["reward_energy"] as? NSNumber)?.doubleValue ?? 0
        if env.code != 0 {
            let message = env.msg.isEmpty ? "code=\(env.code)" : env.msg
            if message.contains("already") || message.contains("已领取") || message.contains("已领") {
                return (true, 0, "\(code)：已领过")
            }
            return (false, 0, "\(code)：\(message)")
        }
        var text = "\(code)：+\(Int(credit)) 积分"
        if energy > 0 { text += " +\(Int(energy)) 能量" }
        if credit == 0 && energy == 0 { text = "\(code)：已领取" }
        return (true, credit, text)
    }

    // MARK: - 连登兑换 + 抽奖

    func runStreak(_ account: Account) async -> RunResult {
        var out = RunResult()
        guard let resp = try? await growth(account, "/activity/growth/streak", method: "GET"),
              let data = resp.data as? [String: Any] else {
            out.steps.append(TaskStep(label: "streak", ok: false, message: "\(account.displayName)：连登状态读取失败"))
            return out
        }
        let redemption = (data["redemption_status"] as? [String: Any]) ?? [:]
        let tiers = (redemption["tiers"] as? [[String: Any]]) ?? []
        var redeemable: [(id: String, credit: Double, chances: Int)] = []
        for tier in tiers {
            guard let id = tier["tier"] as? String else { continue }
            let status = ((redemption["tier_\(id)_status"] as? String) ?? "").lowercased()
            if status == "locked" || status == "claimed" { continue }
            redeemable.append((id,
                               (tier["credit"] as? NSNumber)?.doubleValue ?? 0,
                               (tier["chances"] as? NSNumber)?.intValue ?? 0))
        }
        for tier in redeemable {
            do {
                _ = try await growth(account, "/activity/growth/redeem",
                                     body: ["tier": tier.id, "client_token": UUID().uuidString])
                out.creditEarned += tier.credit
                out.steps.append(TaskStep(label: "redeem-\(tier.id)", ok: true,
                                          message: "兑换 \(tier.id) 档：+\(Int(tier.credit)) 积分" +
                                          (tier.chances > 0 ? "、抽奖 ×\(tier.chances)" : "")))
            } catch {
                let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
                out.steps.append(TaskStep(label: "redeem-\(tier.id)", ok: false, message: "兑换 \(tier.id) 档未生效：\(message)"))
            }
        }

        var chances = 0
        if let summary = try? await growth(account, "/activity/growth/lottery/summary", method: "GET"),
           let data = summary.data as? [String: Any] {
            chances = (data["chances"] as? NSNumber)?.intValue ?? 0
        }
        var drawn = 0
        var won: Double = 0
        for _ in 0..<max(0, min(chances, 20)) {
            guard let env = try? await growth(account, "/activity/growth/lottery/draw",
                                              body: ["client_token": UUID().uuidString]) else { break }
            if let data = env.data as? [String: Any] {
                won += (data["credit"] as? NSNumber)?.doubleValue ?? 0
            }
            drawn += 1
        }
        if drawn > 0 {
            out.creditEarned += won
            out.steps.append(TaskStep(label: "lottery", ok: true,
                                      message: "抽奖 \(drawn) 次" + (won > 0 ? "，共 +\(Int(won)) 积分" : "")))
        }
        if redeemable.isEmpty && drawn == 0 {
            out.steps.append(TaskStep(label: "streak", ok: true, message: "\(account.displayName)：连登无可兑换档位"))
        }
        return out
    }

    // MARK: - 补签

    func useMakeupCard(_ account: Account) async -> TaskStep? {
        guard let resp = try? await growth(account, "/activity/growth/heatmap", method: "GET"),
              let data = resp.data as? [String: Any],
              let cells = data["cells"] as? [[String: Any]] else { return nil }
        let yesterday = Self.dayKey(offset: -1)
        let missed = cells.contains { cell in
            let date = String(((cell["date"] as? String) ?? "").prefix(10))
            return date == yesterday && ((cell["score"] as? NSNumber)?.intValue ?? 0) == 0
        }
        guard missed else { return nil }
        do {
            _ = try await growth(account, "/activity/growth/makeup-cards/use", body: ["target_date": yesterday])
            return TaskStep(label: "makeup", ok: true, message: "\(account.displayName)：已补签 \(yesterday)")
        } catch {
            let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
            return TaskStep(label: "makeup", ok: false, message: "\(account.displayName)：补签未生效 \(message)")
        }
    }

    // MARK: - 礼包 / 补偿

    func claimOneOff(_ account: Account) async -> TaskStep {
        var messages: [String] = []
        var earned: Double = 0
        for (path, label) in [("/billing/meter/claim-gift", "新手礼包"),
                              ("/billing/meter/claim-compensation", "活动补偿")] {
            do {
                var env: Net.Envelope
                do {
                    env = try await meter(account, "/v2" + path, body: [String: Any]())
                } catch {
                    env = try await meter(account, path, body: [String: Any]())
                }
                let credit = ((env.data as? [String: Any])?["credit"] as? NSNumber)?.doubleValue ?? 0
                earned += credit
                messages.append(credit > 0 ? "\(label) +\(Int(credit))" : "\(label)已领取")
            } catch {
                let message = (error as? Wire.UpstreamError)?.message ?? ""
                if !message.contains("already") && !message.contains("已领") && !message.isEmpty {
                    messages.append("\(label)失败")
                }
            }
        }
        return TaskStep(label: "gift", ok: !messages.isEmpty,
                        message: messages.isEmpty ? "礼包/补偿无可领取项" : messages.joined(separator: "，"))
    }


    // MARK: - 活动页任务（/portal/activity/*，判据在活动页，与成长中心两套契约）

    struct CampaignSpec {
        var code: String
        var label: String
        var pageName: String
        var tasks: [(code: String, label: String, credit: Int)]
    }

    static let campaigns: [CampaignSpec] = [
        CampaignSpec(code: "campaign_starbucks_2026", label: "星巴克协作",
                     pageName: "starbucks_activity",
                     tasks: [(code: "ai_chat", label: "与 AI 对话3次", credit: 100),
                             (code: "expert", label: "召唤专家并对话", credit: 100),
                             (code: "app", label: "解锁 App 强大能力", credit: 100)]),
        CampaignSpec(code: "campaign_reporter_2026", label: "记者节福利",
                     pageName: "journalist_benefit",
                     tasks: [(code: "expert_chat", label: "体验媒体工作助理", credit: 50),
                             (code: "skill_use", label: "体验采访素材整理", credit: 50),
                             (code: "desktop_same", label: "体验内容发布排期灵感", credit: 100)]),
    ]

    private func campaignHeaders(_ account: Account) -> [String: String] {
        var h = Wire.mpReportHeaders
        h["Authorization"] = "Bearer \(account.accessToken)"
        if !account.uid.isEmpty { h["X-User-Id"] = account.uid }
        return h
    }

    /// 读活动任务进度：{task_code: (progress, target, completed, claimed)}
    private func campaignTasks(_ account: Account, camp: String) async -> [String: (Int, Int, Bool, Bool)] {
        var out: [String: (Int, Int, Bool, Bool)] = [:]
        let bases = ["https://www.codebuddy.cn", "https://www.workbuddy.cn"]
        for base in bases {
            guard let resp = try? await net.send(base + "/portal/activity/tasks?activity_code=\(camp)",
                                                  method: "GET", headers: campaignHeaders(account)),
                  resp.status < 400, let env = Net.envelope(resp), env.code == 0,
                  let data = env.data as? [String: Any],
                  let progress = data["progress"] as? [[String: Any]] else { continue }
            for row in progress {
                guard let code = row["task_code"] as? String else { continue }
                let current = (row["progress"] as? NSNumber)?.intValue ?? 0
                let target = (row["target"] as? NSNumber)?.intValue ?? 0
                let completed = row["completed_at"] != nil && !(row["completed_at"] is NSNull)
                let claimed = row["claimed_at"] != nil && !(row["claimed_at"] is NSNull)
                out[code] = (current, target, completed, claimed)
            }
            return out
        }
        return out
    }

    /// 活动埋点：带页面上下文（判据按页认人）。
    private func campaignEvents(_ account: Account, spec: CampaignSpec, task: String) -> [[String: Any]] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let conv = Hashing.conversationID()
        let rid = Hashing.requestID()
        let base: [String: Any] = [
            "timestamp": now, "reportDelay": 0, "ideType": "WorkBuddy_MP", "ideVersion": "2.4.0",
            "extName": "workbuddy-mp", "extVersion": "2.4.0", "product": "SaaS",
            "ideName": "wx_app_cloud", "platform": "mini_program", "source": "mini_program",
            "os": "android", "osVersion": "14", "arch": "arm64", "timezone": "Asia/Shanghai",
            "machineId": Hashing.uuidFrom("mp:\(account.uid)"), "userId": account.uid,
            "userNickname": account.nickname, "activityId": spec.code,
            "pageName": spec.pageName,
            "pageURL": "subpackages/\(spec.pageName)/index",
        ]
        func chat(_ extra: [String: Any] = [:]) -> [String: Any] {
            var e: [String: Any] = [
                "eventCode": "chat_request_send", "mode": "chat", "inputLength": 14, "isPlan": false,
                "isAutoExecuteTerminal": false, "isAutoModify": false, "codebaseEnable": false,
                "maxToken": 0, "maxSteps": 500, "temperature": 0, "maxRetries": 0,
                "mentionContexts": [String](), "knowledgeId": [String](), "knowledgeName": [String](),
                "codebaseId": "", "mentionContextCount": 0, "command": "", "recommendId": "",
                "skillId": "", "skillCount": 0, "totalCount": 0, "requestId": rid, "traceId": rid,
                "rootRequestId": rid, "parentConversationId": conv, "conversationId": conv,
                "messageId": "msg-" + String(rid.suffix(8)), "agentName": "mp", "agentType": "main",
            ]
            for (k, v) in extra { e[k] = v }
            return e
        }
        switch task {
        case "ai_chat":
            return (0..<3).map { _ in base.merging(chat()) { _, b in b } }
        case "expert", "expert_chat":
            let expert = "ex_NaiDbO06Adf3"
            let events: [[String: Any]] = [
                chat(["expertId": expert, "expertName": "媒体工作助理"]),
                ["eventCode": "expert_summon_click", "id": expert, "name": expert,
                 "expertTitle": "媒体工作助理", "type": "activity", "position": 0],
                ["eventCode": "expert_summoned", "id": expert, "name": expert,
                 "expertTitle": "媒体工作助理"],
            ]
            return events.map { base.merging($0) { _, b in b } }
        case "skill_use":
            let skillId = "skill_2117491159283752960"
            let name = "interview-material-organizer"
            let info: [String: Any] = ["eventCode": "skill_info", "id": name, "skillId": skillId,
                                       "skillName": name, "skillType": "market",
                                       "skillSource": "market", "position": 0, "conversationId": conv]
            return [info, chat(["skillId": skillId])].map { base.merging($0) { _, b in b } }
        case "app":
            return [["eventCode": "app_enter_click", "mode": "LOCAL"],
                    ["eventCode": "app_show", "mode": "LOCAL"]].map { base.merging($0) { _, b in b } }
        default:
            return [chat()].map { base.merging($0) { _, b in b } }
        }
    }

    func runCampaigns(_ account: Account) async -> RunResult {
        var out = RunResult()
        guard account.realm == .cn else { return out }
        for spec in Self.campaigns {
            let before = await campaignTasks(account, camp: spec.code)
            guard !before.isEmpty else { continue }
            var changed = false
            for task in spec.tasks {
                guard let row = before[task.code], !row.3 else { continue }
                if row.2 == false {
                    do {
                        try await report(account, campaignEvents(account, spec: spec, task: task.code), mp: true)
                        changed = true
                        // 建进度行：need_view 任务必须先 viewed
                        for base in ["https://www.codebuddy.cn", "https://www.workbuddy.cn"] {
                            _ = try? await net.send(base + "/portal/activity/tasks/\(task.code)/viewed?activity_code=\(spec.code)",
                                                     method: "POST", headers: campaignHeaders(account),
                                                     body: Data("{}".utf8))
                        }
                    } catch {
                        out.steps.append(TaskStep(label: "\(spec.label)/\(task.code)", ok: false,
                                                  message: "埋点失败 \((error as? Wire.UpstreamError)?.message ?? "")"))
                    }
                }
                if changed { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                let after = await campaignTasks(account, camp: spec.code)
                guard let now = after[task.code], now.2, !now.3 else { continue }
                for base in ["https://www.codebuddy.cn", "https://www.workbuddy.cn"] {
                    guard let resp = try? await net.send(base + "/portal/activity/tasks/\(task.code)/claim?activity_code=\(spec.code)",
                                                          method: "POST", headers: campaignHeaders(account),
                                                          body: Data("{}".utf8)),
                          resp.status < 400, let env = Net.envelope(resp), env.code == 0 else { continue }
                    _ = env
                    out.creditEarned += Double(task.credit)
                    out.steps.append(TaskStep(label: "\(spec.label)/\(task.code)", ok: true,
                                              message: "\(spec.label)：\(task.label) +\(task.credit) 积分"))
                    break
                }
            }
        }
        return out
    }

    // MARK: - 猫猫旅行

    func travel(_ account: Account) async -> [TaskStep] {
        var steps: [TaskStep] = []
        func status() async -> [String: Any]? {
            guard let env = try? await growth(account, "/activity/growth/buddy/travel/status", method: "GET") else { return nil }
            return env.data as? [String: Any]
        }
        guard var state = await status() else {
            steps.append(TaskStep(label: "travel", ok: false, message: "\(account.displayName)：旅行状态读取失败"))
            return steps
        }
        var phase = (state["state"] as? String) ?? ""
        if phase.isEmpty {
            _ = try? await growth(account, "/activity/growth/buddy/agreement", body: ["agree": true])
            if let env = try? await growth(account, "/activity/growth/buddy/first", body: [String: Any]()) {
                steps.append(TaskStep(label: "buddy", ok: env.code == 0,
                                      message: env.code == 0 ? "\(account.displayName)：已领养第一只 Buddy"
                                                             : "\(account.displayName)：领养未生效 \(env.msg)"))
            }
            state = await status() ?? state
            phase = (state["state"] as? String) ?? ""
        }
        let recordID = (state["record_id"] as? NSNumber)?.int64Value ?? 0
        if phase == "arrived" && recordID != 0 {
            do {
                let env = try await growth(account, "/activity/growth/buddy/travel/claim", body: ["record_id": recordID])
                let credit = ((env.data as? [String: Any])?["reward_credit"] as? NSNumber)?.doubleValue ?? 0
                steps.append(TaskStep(label: "travel", ok: true,
                                      message: credit > 0 ? "\(account.displayName)：旅行奖励 +\(Int(credit)) 积分"
                                                          : "\(account.displayName)：旅行奖励已领取"))
            } catch {
                let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
                steps.append(TaskStep(label: "travel", ok: false, message: "\(account.displayName)：领取旅行奖励失败 \(message)"))
            }
            return steps
        }
        if phase == "traveling" {
            let arriveAt = (state["arrive_at"] as? NSNumber)?.doubleValue ?? 0
            let minutes = arriveAt > 0 ? max(0, Int((arriveAt - Date().timeIntervalSince1970) / 60)) : 0
            steps.append(TaskStep(label: "travel", ok: false,
                                  message: "\(account.displayName)：猫猫还在路上，约 \(minutes) 分钟后到站"))
            return steps
        }
        if (state["daily_limit_reached"] as? Bool) == true {
            steps.append(TaskStep(label: "travel", ok: false, message: "\(account.displayName)：今日已派出过猫猫"))
            return steps
        }
        do {
            _ = try await growth(account, "/activity/growth/buddy/travel/depart", body: ["location_id": 4])
            let after = await status()
            let arriveAt = (after?["arrive_at"] as? NSNumber)?.doubleValue ?? 0
            let minutes = arriveAt > 0 ? max(0, Int((arriveAt - Date().timeIntervalSince1970) / 60)) : 60
            steps.append(TaskStep(label: "travel", ok: true,
                                  message: "\(account.displayName)：猫猫已出发，约 \(minutes) 分钟后到站"))
        } catch {
            let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
            steps.append(TaskStep(label: "travel", ok: false, message: "\(account.displayName)：派出失败 \(message)"))
        }
        return steps
    }

    // MARK: - 夜猫子

    func runNightWindow() async -> RunResult {
        var out = RunResult()
        for account in store.activeAccounts where account.realm == .cn {
            let fresh = await up.ensureFresh(account)
            var headers = Wire.mpReportHeaders
            headers["Authorization"] = "Bearer \(fresh.accessToken)"
            headers["X-User-Id"] = fresh.uid
            let conv = Hashing.conversationID()
            let rid = Hashing.requestID()
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let event: [String: Any] = [
                "eventCode": "chat_request_send", "timestamp": now, "reportDelay": 0,
                "ideType": "WorkBuddy_MP", "ideVersion": "2.4.0", "extName": "workbuddy-mp",
                "extVersion": "2.4.0", "product": "SaaS", "ideName": "wx_app_cloud",
                "platform": "mini_program", "source": "mini_program", "os": "android",
                "osVersion": "14", "arch": "arm64", "timezone": "Asia/Shanghai",
                "machineId": Hashing.uuidFrom("mp:\(fresh.uid)"), "userId": fresh.uid,
                "userNickname": fresh.nickname, "mode": "chat", "inputLength": 12, "isPlan": false,
                "requestModelId": "glm-5.2", "requestModelName": "GLM-5.2",
                "requestId": rid, "traceId": rid, "rootRequestId": rid,
                "parentConversationId": conv, "conversationId": conv,
                "messageId": "msg-" + String(rid.suffix(8)), "agentName": "mp", "agentType": "main",
            ]
            do {
                _ = try await request(Wire.billingBases(for: fresh, override: up.baseOverride(for: fresh)),
                                      path: "/v2/report", headers: headers, body: [event])
                out.steps.append(TaskStep(label: "night", ok: true, message: "\(fresh.displayName)：夜猫子对话已上报"))
            } catch {
                let message = (error as? Wire.UpstreamError)?.message ?? error.localizedDescription
                out.steps.append(TaskStep(label: "night", ok: false, message: "\(fresh.displayName)：夜猫子上报失败 \(message)"))
            }
        }
        return out
    }

    // MARK: - helpers

    private func desktopEvent(account: Account, code: String, conversation: String,
                              request: String, modelID: String) -> [String: Any] {
        [
            "eventCode": code, "inputLength": 24, "isPlan": false, "isAutoExecuteTerminal": false,
            "isAutoModify": false, "codebaseEnable": false, "maxToken": 0, "maxSteps": 500,
            "temperature": 0, "maxRetries": 0, "mentionContexts": [String](), "knowledgeId": [String](),
            "knowledgeName": [String](), "codebaseId": "", "mentionContextCount": 0, "command": "",
            "recommendId": "", "skillId": "", "skillCount": 0, "totalCount": 0, "requestId": request,
            "traceId": request, "rootRequestId": request, "parentConversationId": conversation,
            "conversationId": conversation, "agentName": "default", "agentType": "conversation",
            "userId": account.uid, "requestModelId": modelID, "requestModelName": modelID,
        ]
    }

    private func desktopFingerprint(account: Account) -> [String: Any] {
        [
            "timestamp": Int(Date().timeIntervalSince1970 * 1000), "reportDelay": 0,
            "userId": account.uid, "userNickname": account.nickname,
            "ideName": "WorkBuddy", "ideType": "WorkBuddy", "ideVersion": account.realm.clientVersion,
            "extName": "WorkBuddy", "extVersion": account.realm.clientVersion,
            "product": "SaaS", "platform": "mac", "os": "darwin", "osVersion": "14.5",
            "arch": "arm64", "timezone": "Asia/Shanghai",
            "machineId": Hashing.sha256Hex("wbhub:machine:\(account.uid)", length: 36),
        ]
    }

    static func dayKey(offset: Int = 0) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let date = cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = cal.timeZone
        return f.string(from: date)
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date())
    }
}

extension TaskRunner {
    /// 从界面一键触发：置运行态、写任务列表、提示结果。
    func runFromUI(store: AppStore) async {
        guard !store.taskRunning else { return }
        store.taskRunning = true
        store.currentTasks = [TaskStep(label: "start", ok: true, message: "开始执行每日任务…")]
        store.log("一键任务开始", .info)
        let result = await runAll()
        store.currentTasks = result.steps
        store.taskRunning = false
        store.lastError = result.okCount == 0 ? "全部步骤失败，请看日志" : ""
    }
}
