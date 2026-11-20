import Foundation
import CryptoKit
import Security


/// 与全局 actor 无关的常量，任何上下文都能读。
enum AppInfo {
    static let version = "1.0.0"
    static let author = "小帅"
    static let authorQQ = "57844458"
    static let repo = "WBHub"
}

enum Realm: String, Codable, CaseIterable {
    case cn
    case global
    var label: String { self == .cn ? "国内版" : "国际版" }
    var chatBase: String { self == .global ? "https://www.workbuddy.ai" : "https://copilot.tencent.com" }
    var billingBase: String { self == .global ? "https://www.workbuddy.ai" : "https://www.codebuddy.cn" }
    var origin: String { self == .global ? "https://www.workbuddy.ai" : "https://www.codebuddy.cn" }
    var clientVersion: String { self == .global ? "5.5.4" : "5.9.3" }
    var cliVersion: String { self == .global ? "2.137.1" : "2.165.0" }
    var platformSegment: String { self == .global ? "WorkBuddy AI" : "WorkBuddy" }
    /// 出站 UA：与官方桌面端 RestOperations 层同形。
    var userAgent: String { "WorkBuddy/\(clientVersion) \(platformSegment)/\(clientVersion) CLI/\(cliVersion)" }
}

struct Account: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var nickname: String = ""
    var uid: String = ""
    var accessToken: String = ""
    var refreshToken: String = ""
    var expiresAt: Double = 0
    var domain: String = ""
    var enterpriseID: String = ""
    var realm: Realm = .cn
    var deviceToken: String = ""
    var disabled: Bool = false
    var credits: Double = 0
    var lastCheckin: String = ""
    var lastRun: String = ""
    var createdAt: Double = Date().timeIntervalSince1970

    enum CodingKeys: String, CodingKey {
        case id, nickname, uid, accessToken, refreshToken, expiresAt, domain, enterpriseID,
             realm, deviceToken, disabled, credits, lastCheckin, lastRun, createdAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        nickname = (try? c.decode(String.self, forKey: .nickname)) ?? ""
        uid = (try? c.decode(String.self, forKey: .uid)) ?? ""
        accessToken = (try? c.decode(String.self, forKey: .accessToken)) ?? ""
        refreshToken = (try? c.decode(String.self, forKey: .refreshToken)) ?? ""
        expiresAt = (try? c.decode(Double.self, forKey: .expiresAt)) ?? 0
        domain = (try? c.decode(String.self, forKey: .domain)) ?? ""
        enterpriseID = (try? c.decode(String.self, forKey: .enterpriseID)) ?? ""
        realm = (try? c.decode(Realm.self, forKey: .realm)) ?? .cn
        deviceToken = (try? c.decode(String.self, forKey: .deviceToken)) ?? ""
        disabled = (try? c.decode(Bool.self, forKey: .disabled)) ?? false
        credits = (try? c.decode(Double.self, forKey: .credits)) ?? 0
        lastCheckin = (try? c.decode(String.self, forKey: .lastCheckin)) ?? ""
        lastRun = (try? c.decode(String.self, forKey: .lastRun)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? Date().timeIntervalSince1970
    }

    var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !uid.isEmpty { return String(uid.prefix(10)) }
        return "未命名账号"
    }
    var tokenExpired: Bool { expiresAt > 0 && expiresAt < Date().timeIntervalSince1970 + 60 }

    /// 账号维度稳定设备指纹（跨重启恒定、账号间互异）。
    func stableID(_ purpose: String) -> String {
        let seed = "wbhub:\(purpose):\(uid)"
        return Hashing.sha256Hex(seed, length: 36)
    }
}

enum PromptMode: String, Codable, CaseIterable {
    case off, append, prepend, replace
    var label: String {
        switch self {
        case .off: return "不处理"
        case .append: return "追加到末尾"
        case .prepend: return "插入到开头"
        case .replace: return "整体替换"
        }
    }
}

/// 保活策略。iOS 上唯一能真正长期后台驻留的只有「音频会话」，
/// 其余手段（BGTaskScheduler / beginBackgroundTask）都只是续命，系统随时会回收。
enum KeepAliveMode: String, Codable, CaseIterable {
    /// 仅系统续期：零功耗，但切后台几分钟内就会被挂起
    case system = "sys"
    /// 真后台 · 省电：8kHz 单声道静音循环，CPU/音频硬件都在最低功耗档
    case audioEco = "eco"
    /// 真后台 · 稳定：44.1kHz 静音循环，兼容性最好，功耗略高
    case audioStd = "std"

    var label: String {
        switch self {
        case .system: return "仅系统"
        case .audioEco: return "真后台·省电"
        case .audioStd: return "真后台·稳定"
        }
    }

    /// 是否会真正占用音频会话（决定能不能后台常驻）
    var usesAudio: Bool { self != .system }

    /// 相对功耗
    var cost: String {
        switch self {
        case .system: return "零功耗 · 但会被杀"
        case .audioEco: return "约 1%/小时"
        case .audioStd: return "约 2-3%/小时"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "只用 BGTask 续期。切后台约 3-10 分钟后连接断开，长时间不用时不可靠。"
        case .audioEco:
            return "8kHz 单声道 1 秒静音循环，音频硬件运行在最低功耗档。可长期后台存活，无明显发热。"
        case .audioStd:
            return "44.1kHz 静音循环，后台存活最稳，但长时间运行可能有轻微温热，不建议长期开启。"
        }
    }

    /// 采样率
    var sampleRate: Int {
        switch self {
        case .system: return 0
        case .audioEco: return 8000
        case .audioStd: return 44100
        }
    }
}

struct Settings: Codable, Equatable {
    var port: Int = 8788
    var apiKey: String = "sk-wbhub"
    var requireAuth: Bool = true
    var autoStart: Bool = true
    var defaultModel: String = "auto"
    var promptMode: PromptMode = .append
    var promptText: String = Presets.defaultPrompt
    var disguise: Bool = true
    var forceStreamOptions: Bool = true
    var retries: Int = 2
    var autoTask: Bool = true
    var taskHour: Int = 7
    var taskMinute: Int = 5
    var nightTask: Bool = true
    var backgroundKeepAlive: Bool = false
    var keepAliveMode: KeepAliveMode = .audioEco
    var enableAnthropic: Bool = true
    var enableResponses: Bool = true
    var cnBaseOverride: String = ""
    var globalBaseOverride: String = ""
    var requestTimeout: Int = 300

    enum CodingKeys: String, CodingKey {
        case port, apiKey, requireAuth, autoStart, defaultModel, promptMode, promptText, disguise,
             forceStreamOptions, retries, autoTask, taskHour, taskMinute, nightTask,
             backgroundKeepAlive, keepAliveMode, enableAnthropic, enableResponses,
             cnBaseOverride, globalBaseOverride, requestTimeout
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        port = value(.port, 8788)
        apiKey = value(.apiKey, "sk-wbhub")
        requireAuth = value(.requireAuth, true)
        autoStart = value(.autoStart, true)
        defaultModel = value(.defaultModel, "auto")
        promptMode = value(.promptMode, .append)
        promptText = value(.promptText, Presets.defaultPrompt)
        disguise = value(.disguise, true)
        forceStreamOptions = value(.forceStreamOptions, true)
        retries = value(.retries, 2)
        autoTask = value(.autoTask, true)
        taskHour = value(.taskHour, 7)
        taskMinute = value(.taskMinute, 5)
        nightTask = value(.nightTask, true)
        backgroundKeepAlive = value(.backgroundKeepAlive, false)
        keepAliveMode = value(.keepAliveMode, .audioEco)
        enableAnthropic = value(.enableAnthropic, true)
        enableResponses = value(.enableResponses, true)
        cnBaseOverride = value(.cnBaseOverride, "")
        globalBaseOverride = value(.globalBaseOverride, "")
        requestTimeout = value(.requestTimeout, 300)
    }
}

struct LogLine: Identifiable, Hashable {
    let id = UUID()
    let time = Date()
    let level: Level
    let text: String
    enum Level: String { case info = "INFO", ok = "OK", warn = "WARN", err = "ERR" }
    var stamp: String { LogLine.formatter.string(from: time) }
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 一次反代请求的完整记录：模型、上游链接、token 消耗、耗时。
struct RequestLog: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var time: Date = Date()
    /// 客户端请求的模型名
    var model: String = ""
    /// 实际发往上游的 chat 链接（含 base，脱敏后只留 host+path）
    var upstreamURL: String = ""
    /// 使用的账号昵称
    var account: String = ""
    /// 协议方言：openai / anthropic / responses
    var dialect: String = "openai"
    /// 是否流式
    var streamed: Bool = true
    /// HTTP 状态
    var status: Int = 0
    /// prompt tokens
    var promptTokens: Int = 0
    /// completion tokens
    var completionTokens: Int = 0
    /// reasoning tokens（上游可能单独给）
    var reasoningTokens: Int = 0
    /// 总 tokens
    var totalTokens: Int = 0
    /// 耗时毫秒
    var elapsedMs: Int = 0
    /// 失败原因（空 = 成功）
    var error: String = ""

    var ok: Bool { error.isEmpty && status >= 200 && status < 300 }
    var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: time)
    }
    var tokenSummary: String {
        if totalTokens > 0 {
            return "in \(promptTokens) · out \(completionTokens) · 共 \(totalTokens)"
        }
        return "未返回用量"
    }
    var elapsedText: String {
        elapsedMs >= 1000 ? String(format: "%.1fs", Double(elapsedMs) / 1000) : "\(elapsedMs)ms"
    }
}

struct TaskStep: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let ok: Bool
    let message: String
}

struct RemoteModel: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var contextWindow: Int
    var maxTokens: Int
    var supportsImages: Bool
    var credits: String
    var efforts: [String]
    var description: String
}

enum Hashing {
    /// 截断的 sha256 hex，用于稳定派生 36 hex 设备/会话标识。
    static func sha256Hex(_ text: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func uuidFrom(_ text: String) -> String {
        let chars = Array(md5Hex(text))
        func seg(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }
        return "\(seg(0, 8))-\(seg(8, 12))-\(seg(12, 16))-\(seg(16, 20))-\(seg(20, 32))"
    }
    static func randomHex(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    static func requestID() -> String { randomHex(16) }
    static func conversationID() -> String {
        var s = Array(randomHex(16))
        s[12] = "4"
        let variant = "89ab"
        s[16] = Array(variant)[Int.random(in: 0..<4)]
        let str = String(s)
        let chars = Array(str)
        func seg(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }
        return "\(seg(0, 8))-\(seg(8, 12))-\(seg(12, 16))-\(seg(16, 20))-\(seg(20, 32))"
    }
}
