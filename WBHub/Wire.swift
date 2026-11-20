import Foundation

/// 上游线协议：base/头/信封/分类/请求体整形，逐条对齐实测行为。
enum Wire {

    enum ErrorKind: String {
        case hardCredit, softRate, sessionDead, notFound, server, client, transport
        var httpStatus: Int {
            switch self {
            case .hardCredit: return 402
            case .softRate: return 429
            case .sessionDead: return 401
            case .notFound: return 404
            case .server, .transport: return 502
            case .client: return 400
            }
        }
    }

    struct UpstreamError: Error {
        var kind: ErrorKind
        var status: Int
        var message: String
    }

    static let hardCreditMarkers = [
        "insufficient credit", "no credit", "credit exhausted", "credits exhausted", "out of credit",
        "quota exceeded", "quota exhaust", "payment required", "credit not enough", "not enough credit",
        "积分不足", "额度不足", "余额不足", "积分用完", "额度用尽", "没有积分",
    ]
    static let sessionDeadMarkers = ["Offline user session not found", "12153", "session not found"]

    static func classify(status: Int, body: String) -> ErrorKind {
        if status == 402 { return .hardCredit }
        if status == 401 { return .sessionDead }
        let lower = body.lowercased()
        if hardCreditMarkers.contains(where: { lower.contains($0.lowercased()) || body.contains($0) }) {
            return .hardCredit
        }
        if sessionDeadMarkers.contains(where: { body.contains($0) }) { return .sessionDead }
        if status == 429 { return .softRate }
        if status == 404 { return .notFound }
        if status >= 500 { return .server }
        return .client
    }

    /// 优先取上游本地化的 displayMsg，其次 msg。
    static func displayError(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let display = obj["displayMsg"] as? [String: Any] {
            if let zh = (display["zh"] as? String)?.trimmingCharacters(in: .whitespaces), !zh.isEmpty { return zh }
            if let en = (display["en"] as? String)?.trimmingCharacters(in: .whitespaces), !en.isEmpty { return en }
        }
        if let msg = (obj["msg"] as? String)?.trimmingCharacters(in: .whitespaces), !msg.isEmpty { return msg }
        return nil
    }

    // MARK: - 请求体整形

    /// 强制流式，developer→system，tool_choice 归一化，image_url 归一化。
    static func prepareChatBody(_ source: Data, realm: Realm) -> Data {
        guard var obj = (try? JSONSerialization.jsonObject(with: source)) as? [String: Any] else { return source }
        obj["stream"] = true
        if obj["stream_options"] == nil {
            obj["stream_options"] = ["include_usage": true]
        }
        translateMaxCompletionTokens(&obj)
        normalizeRoles(&obj)
        normalizeToolChoice(&obj)
        normalizeImageURL(&obj)
        normalizeMessages(&obj)
        if realm == .global {
            if (obj["reasoning_effort"] as? String)?.lowercased() == "off" { obj.removeValue(forKey: "reasoning_effort") }
            ensureLeadingSystem(&obj)
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? source
    }

    private static func translateMaxCompletionTokens(_ obj: inout [String: Any]) {
        guard obj["max_tokens"] == nil, let alias = obj["max_completion_tokens"] as? NSNumber,
              alias.doubleValue > 0 else {
            obj.removeValue(forKey: "max_completion_tokens")
            return
        }
        obj["max_tokens"] = alias
        obj.removeValue(forKey: "max_completion_tokens")
    }

    private static func normalizeRoles(_ obj: inout [String: Any]) {
        guard var messages = obj["messages"] as? [[String: Any]] else { return }
        for i in messages.indices where (messages[i]["role"] as? String) == "developer" {
            messages[i]["role"] = "system"
        }
        obj["messages"] = messages
    }

    private static func normalizeToolChoice(_ obj: inout [String: Any]) {
        guard let choice = obj["tool_choice"] else { return }
        func suppress() {
            obj.removeValue(forKey: "tool_choice")
            obj.removeValue(forKey: "tools")
            obj.removeValue(forKey: "functions")
        }
        if let text = choice as? String {
            let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
            if lowered == "none" { suppress() }
            else if lowered == "auto" || lowered == "required" { obj["tool_choice"] = lowered }
            else { obj.removeValue(forKey: "tool_choice") }
            return
        }
        guard let dict = choice as? [String: Any] else { suppress(); return }
        switch ((dict["type"] as? String) ?? "").lowercased() {
        case "none": suppress()
        case "auto", "required": obj["tool_choice"] = (dict["type"] as? String ?? "auto").lowercased()
        case "function":
            let name = ((dict["function"] as? [String: Any])?["name"] as? String) ?? (dict["name"] as? String) ?? ""
            obj["tool_choice"] = name.isEmpty ? "auto" : name
        default: obj.removeValue(forKey: "tool_choice")
        }
    }

    /// 上游只认 OpenAI 对象形态的 image_url，字符串会 400。
    private static func normalizeImageURL(_ obj: inout [String: Any]) {
        guard var messages = obj["messages"] as? [[String: Any]] else { return }
        for i in messages.indices {
            guard var parts = messages[i]["content"] as? [[String: Any]] else { continue }
            var changed = false
            for j in parts.indices {
                guard (parts[j]["type"] as? String) == "image_url",
                      let raw = parts[j]["image_url"] as? String else { continue }
                parts[j]["image_url"] = ["url": raw]
                changed = true
            }
            if changed {
                messages[i]["content"] = parts
            }
        }
        obj["messages"] = messages
    }

    /// assistant.tool_calls 与 tool 结果配对清理：不完整配对会让上游对后续每条消息 400。
    private static func normalizeMessages(_ obj: inout [String: Any]) {
        guard var messages = obj["messages"] as? [[String: Any]], !messages.isEmpty else { return }
        var callIDs = Set<String>()
        var kept: [[String: Any]] = []
        for var message in messages {
            let role = message["role"] as? String ?? ""
            if role == "assistant", let calls = message["tool_calls"] as? [[String: Any]] {
                let ids = calls.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
                if ids.isEmpty {
                    message.removeValue(forKey: "tool_calls")
                } else {
                    callIDs.formUnion(ids)
                }
            }
            if role == "tool" {
                let id = message["tool_call_id"] as? String ?? ""
                if callIDs.contains(id) {
                    kept.append(message)
                }
                continue
            }
            kept.append(message)
        }
        obj["messages"] = kept
    }

    private static func ensureLeadingSystem(_ obj: inout [String: Any]) {
        guard var messages = obj["messages"] as? [[String: Any]] else { return }
        if let first = messages.first, (first["role"] as? String) == "system" { return }
        messages.insert(["role": "system", "content": "You are a helpful assistant."], at: 0)
        obj["messages"] = messages
    }

    // MARK: - 头

    static func commonHeaders(realm: Realm, uid: String, domain: String, enterpriseID: String) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": realm.origin,
            "Referer": realm.origin + "/",
            "User-Agent": realm.userAgent,
            "X-CodeBuddy-Request": "1",
            "Accept-Language": realm == .global ? "en-US" : "zh-CN",
        ]
        if !uid.isEmpty {
            h["X-Machine-ID"] = Hashing.sha256Hex("wbhub:machine:\(uid)", length: 36)
            h["X-Session-ID"] = Hashing.sha256Hex("wbhub:session:\(uid)", length: 36)
        }
        return h
    }

    static func chatHeaders(account: Account, clientIP: String?, conversationID: String) -> [String: String] {
        let realm = account.realm
        var h = commonHeaders(realm: realm, uid: account.uid, domain: account.domain, enterpriseID: account.enterpriseID)
        h["Accept"] = "application/json, text/event-stream"
        h["Authorization"] = "Bearer \(account.accessToken)"
        if account.uid.isEmpty { h["X-No-User-Id"] = "1" } else { h["X-User-Id"] = account.uid }
        if realm == .global {
            h["X-No-Enterprise-Id"] = "1"
            h["X-Domain"] = "www.workbuddy.ai"
        } else {
            if account.enterpriseID.isEmpty { h["X-No-Enterprise-Id"] = "1" }
            else { h["X-Enterprise-Id"] = account.enterpriseID }
            if account.domain.isEmpty { h["X-No-Department-Info"] = "1" }
            else { h["X-Domain"] = account.domain }
        }
        h["X-Agent-Purpose"] = "conversation"
        h["X-IDE-Name"] = "WorkBuddy"
        h["X-IDE-Type"] = "WorkBuddy"
        h["X-IDE-Version"] = realm.clientVersion
        h["X-Product"] = "WorkBuddy"
        if !account.deviceToken.isEmpty { h["X-Device-Token"] = account.deviceToken }
        let messageID = Hashing.requestID()
        h["X-Conversation-ID"] = conversationID
        h["X-Conversation-Request-ID"] = Hashing.requestID()
        h["X-Conversation-Message-ID"] = messageID
        h["X-Request-ID"] = messageID
        h["X-Root-Request-ID"] = h["X-Conversation-Request-ID"]
        h["X-Trace-ID"] = h["X-Conversation-Request-ID"] ?? ""
        h["X-B3-TraceId"] = h["X-Conversation-Request-ID"] ?? ""
        h["X-B3-SpanId"] = String(messageID.prefix(16))
        h["X-B3-Sampled"] = "1"
        if let ip = clientIP, !ip.isEmpty {
            h["X-Forwarded-For"] = ip
            h["X-Real-IP"] = ip
            h["X-Client-IP"] = ip
        }
        return h
    }

    static func billingHeaders(account: Account) -> [String: String] {
        var h: [String: String] = [
            "Authorization": "Bearer \(account.accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-CodeBuddy-Request": "1",
            "Accept-Language": account.realm == .global ? "en-US" : "zh-CN",
        ]
        h["User-Agent"] = "WorkBuddy/\(account.realm.clientVersion)"
        if !account.uid.isEmpty { h["X-User-Id"] = account.uid }
        if !account.enterpriseID.isEmpty {
            h["X-Enterprise-Id"] = account.enterpriseID
            h["X-Tenant-Id"] = account.enterpriseID
        }
        if !account.domain.isEmpty { h["X-Domain"] = account.domain }
        if !account.deviceToken.isEmpty { h["X-Device-Token"] = account.deviceToken }
        return h
    }

    static func growthHeaders(account: Account) -> [String: String] {
        var h = billingHeaders(account: account)
        h["Origin"] = account.realm.origin
        h["Referer"] = account.realm.origin + "/"
        return h
    }

    static func refreshHeaders(account: Account) -> [String: String] {
        var h = commonHeaders(realm: account.realm, uid: account.uid, domain: account.domain, enterpriseID: account.enterpriseID)
        h["X-Refresh-Token"] = account.refreshToken
        h["X-Auth-Refresh-Source"] = "plugin"
        if !account.enterpriseID.isEmpty { h["X-Enterprise-Id"] = account.enterpriseID }
        return h
    }

    static func loginHeaders(realm: Realm) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": realm.origin,
            "Referer": realm.origin + "/",
            "User-Agent": realm == .global ? "WorkBuddy/5.5.2" : "WorkBuddy/5.9.3",
        ]
    }

    /// 小程序埋点头族（成长任务/活动判据走这套身份）。
    static let mpReportHeaders: [String: String] = [
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-Client-Product": "workbuddy-mp",
        "X-Client-Version": "2.4.0",
        "X-Client-Platform": "mp-weixin",
        "X-Platform": "wechatmp",
    ]

    static let mpListHeaders: [String: String] = [
        "X-Client-Platform": "miniprogram",
        "User-Agent": "Mozilla/5.0 (Linux; Android 14; MicroMessenger/8.0.49 WeChat/0.8.0 MiniProgramEnv/android; wkbrowser xweb)",
    ]

    /// 业务域主机候选：官方两个域历史上都能通，任一可用即可。
    static func growthBases(for account: Account, override: String) -> [String] {
        if !override.isEmpty { return [override] }
        if account.realm == .global { return ["https://www.workbuddy.ai"] }
        return ["https://copilot.tencent.com", "https://www.workbuddy.cn", "https://www.codebuddy.cn"]
    }

    static func billingBases(for account: Account, override: String) -> [String] {
        if !override.isEmpty { return [override] }
        if account.realm == .global { return ["https://www.workbuddy.ai"] }
        return ["https://www.codebuddy.cn", "https://www.workbuddy.cn", "https://copilot.tencent.com"]
    }

    static func chatBase(for account: Account, override: String) -> String {
        if !override.isEmpty { return override }
        return account.realm.chatBase
    }

    static func billingBase(for account: Account, override: String) -> String {
        if !override.isEmpty { return override }
        return account.realm.billingBase
    }
}
