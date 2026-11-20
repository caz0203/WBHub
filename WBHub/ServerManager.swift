import Foundation

/// 反代核心：把 OpenAI / Anthropic / Responses 请求翻译成上游 chat，再把结果翻回来。
@MainActor
final class ServerManager {
    static let shared = ServerManager()

    private let server = HttpServer()
    private var store: AppStore { AppStore.shared }
    private var up: Upstream { Upstream.shared }
    private var rotation: [String: Int] = [:]

    var running: Bool { store.serverRunning }
    var port: Int { store.settings.port }

    /// 共享给流式闭包的可变状态。
    final class StreamState: @unchecked Sendable { var started = false; var sentRole = false }

    /// 把上游 SSE 收集成字符串（非流式请求用），并发安全。
    final class LineBox: @unchecked Sendable {
        private var lines: [String] = []
        private let lock = NSLock()
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var joined: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    struct ChatJob {
        var url: String
        var headers: [String: String]
        var body: Data
        var model: String
    }

    func start() async {
        guard !store.serverRunning else { return }
        let port = store.settings.port
        server.onLog = { message, level in
            Task { @MainActor in AppStore.shared.log(message, level) }
        }
        server.onRequest = { [weak self] request, responder, writer in
            Task { @MainActor in await self?.route(request, responder: responder, writer: writer) }
        }
        do {
            try server.start(port: port)
            store.serverRunning = true
            store.log("反代已启动：\(store.baseURL)", .ok)
        } catch {
            store.serverRunning = false
            store.log("反代启动失败：\(error.localizedDescription)", .err)
        }
        // 首帧模型目录 / 凭证就绪后即可用
    }

    func stop() {
        server.stop()
        store.serverRunning = false
        store.log("反代已停止", .warn)
    }

    func restart() async {
        stop()
        try? await Task.sleep(nanoseconds: 220_000_000)
        await start()
    }

    // MARK: - routing

    private func route(_ request: HttpServer.Request,
                       responder: HttpServer.Responder,
                       writer: HttpServer.StreamWriter) async {
        let path = request.path
        // 鉴权
        if store.settings.requireAuth && !authorized(request) {
            responder.send(HttpServer.Response.error("Invalid API key", status: 401, type: "authentication_error"))
            return
        }
        switch path {
        case "/", "/health", "/v1":
            responder.send(.json(["status": "ok", "service": "WBHub", "version": Self.version,
                           "models": store.models.count, "accounts": store.activeAccounts.count]))
        case "/v1/models":
            responder.send(.json(["object": "list", "data": store.models.map { model -> [String: Any] in
                ["id": model.id, "object": "model", "owned_by": "workbuddy",
                 "created": Int(Date().timeIntervalSince1970),
                 "context_window": model.contextWindow, "max_tokens": model.maxTokens]
            }]))
        case "/v1/chat/completions":
            await chat(request, dialect: .openai, responder: responder, writer: writer)
        case "/v1/messages":
            guard store.settings.enableAnthropic else {
                responder.send(HttpServer.Response.error("Anthropic 协议已关闭", status: 404)); return
            }
            await chat(request, dialect: .anthropic, responder: responder, writer: writer)
        case "/v1/responses":
            guard store.settings.enableResponses else {
                responder.send(HttpServer.Response.error("Responses 协议已关闭", status: 404)); return
            }
            await chat(request, dialect: .responses, responder: responder, writer: writer)
        case "/v1/models/refresh":
            await reloadModels()
            responder.send(.json(["ok": true, "count": store.models.count]))
        case "/v1/completions":
            responder.send(HttpServer.Response.error("上游只支持 chat completions，请用 /v1/chat/completions", status: 400))
        default:
            responder.send(HttpServer.Response.error("Unknown endpoint \(path)", status: 404))
        }
    }

    private func authorized(_ request: HttpServer.Request) -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        let token = header.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespaces)
        if token == store.settings.apiKey { return true }
        if let alt = request.headers["x-api-key"], alt == store.settings.apiKey { return true }
        return false
    }

    enum Dialect: Equatable { case openai, anthropic, responses }

    // MARK: - chat

    private func chat(_ request: HttpServer.Request, dialect: Dialect,
                      responder: HttpServer.Responder,
                      writer: HttpServer.StreamWriter) async {
        guard var body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            responder.send(HttpServer.Response.error("Invalid JSON body", status: 400))
            return
        }
        // 方言统一成 chat completions
        switch dialect {
        case .anthropic: body = PromptEngine.anthropicToChat(body)
        case .responses: body = PromptEngine.responsesToChat(body)
        case .openai: break
        }

        let wantsStream = (body["stream"] as? Bool) ?? false
        let requestedModel = (body["model"] as? String) ?? store.settings.defaultModel
        let model = resolveModel(requestedModel)

        guard let account = pickAccount() else {
            responder.send(HttpServer.Response.error("没有可用账号，请先在 App 内登录 WorkBuddy", status: 503, type: "insufficient_quota"))
            return
        }

        // 提示词改写 + 拦截标记规避 + 请求体整形
        PromptEngine.applySystemPrompt(&body, settings: store.settings)
        if store.settings.disguise { PromptEngine.disguiseMessages(&body) }
        body["stream"] = true
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            responder.send(HttpServer.Response.error("Cannot serialize body", status: 400))
            return
        }
        // 上游拒绝非流式：一律强制流式，非流式请求在本地聚合还原
        let shaped = Wire.prepareChatBody(bodyData, realm: account.realm)

        let fresh = await up.ensureFresh(account)
        let conversation = conversationID(from: body)

        let state = StreamState()
        var lastError: Wire.UpstreamError?
        let attempts = max(1, store.settings.retries + 1)
        for attempt in 0..<attempts {
            let target = attempt == 0 ? fresh : (pickAccount(skip: attempt) ?? fresh)
            let url = Wire.chatBase(for: target, override: up.baseOverride(for: target)) + "/v2/chat/completions"
            var headers = Wire.chatHeaders(account: target, clientIP: nil, conversationID: conversation)
            headers["Content-Type"] = "application/json"
            let job = ChatJob(url: url, headers: headers, body: shaped, model: model)

            do {
                if wantsStream {
                    try await streamChat(job, dialect: dialect, model: model, writer: writer, state: state)
                } else {
                    let box = LineBox()
                    _ = try await Net.shared.stream(job.url, headers: job.headers, body: job.body) { line in
                        box.append(line)
                    }
                    let completion = PromptEngine.aggregate(box.joined, model: model)
                    switch dialect {
                    case .openai:
                        responder.send(.json(completion))
                    case .anthropic:
                        responder.send(.json(PromptEngine.chatToAnthropic(completion, model: model)))
                    case .responses:
                        responder.send(.json(PromptEngine.chatToResponses(completion, model: model)))
                    }
                }
                store.requestCount += 1
                return
            } catch let error as Wire.UpstreamError {
                lastError = error
                store.log("上游 \(error.status)：\(error.message)", .warn)
                if state.started {
                    // 已经发过响应头：用 SSE 错误帧收尾，不再改状态码。
                    let payload = ["type": "error", "error": ["message": error.message, "type": "upstream_error", "code": error.status]] as [String: Any]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let text = String(data: data, encoding: .utf8) {
                        writer.writeText(dialect == .anthropic ? "event: error\ndata: \(text)\n\n" : "data: \(text)\n\n")
                    }
                    writer.finish()
                    return
                }
                if error.kind == .sessionDead, attempt < attempts - 1 {
                    _ = try? await up.refresh(target)
                    continue
                }
                if error.kind == .softRate || error.kind == .server {
                    try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                    continue
                }
                break
            } catch {
                lastError = Wire.UpstreamError(kind: .transport, status: 0, message: error.localizedDescription)
                continue
            }
        }
        let err = lastError ?? Wire.UpstreamError(kind: .server, status: 502, message: "上游无响应")
        store.log("请求失败：\(err.message)", .err)
        if state.started {
            writer.finish()
        } else {
            responder.send(HttpServer.Response.error(err.message, status: err.kind.httpStatus))
        }
    }

    /// 流式：把上游 SSE 逐帧翻成对应方言再写出。首帧到达才发响应头，
    /// 这样上游在出字之前就报错时还能正常回 HTTP 错误码。
    private func streamChat(_ job: ChatJob, dialect: Dialect, model: String,
                            writer: HttpServer.StreamWriter, state: StreamState) async throws {
        let messageID = "chatcmpl-" + Hashing.randomHex(12)
        func ensureStart() {
            guard !state.started else { return }
            state.started = true
            writer.startSSE()
        }

        _ = try await Net.shared.stream(job.url, headers: job.headers, body: job.body) { line in
            var payload = line
            if payload.hasPrefix("data:") { payload = String(payload.dropFirst(5)) }
            payload = payload.trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { return }
            if payload == "[DONE]" {
                ensureStart()
                switch dialect {
                case .openai: writer.writeText("data: [DONE]\n\n")
                case .anthropic: writer.writeText("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
                case .responses: writer.writeText("event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n")
                }
                return
            }
            guard let data = payload.data(using: .utf8),
                  var chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            switch dialect {
            case .openai:
                ensureStart()
                chunk["id"] = messageID
                chunk["model"] = model
                if let frames = chunk["choices"] as? [[String: Any]], !frames.isEmpty {
                    var updated = frames
                    for i in updated.indices { updated[i]["index"] = i }
                    chunk["choices"] = updated
                    state.sentRole = true
                }
                if let out = try? JSONSerialization.data(withJSONObject: chunk),
                   let text = String(data: out, encoding: .utf8) {
                    writer.writeText("data: \(text)\n\n")
                }
            case .anthropic:
                let choice = ((chunk["choices"] as? [[String: Any]]) ?? []).first ?? [:]
                let delta = (choice["delta"] as? [String: Any]) ?? [:]
                let hasBody = (delta["content"] as? String)?.isEmpty == false
                    || (delta["reasoning_content"] as? String)?.isEmpty == false
                    || (choice["finish_reason"] as? String)?.isEmpty == false
                guard hasBody else { return }
                ensureStart()
                if !state.sentRole {
                    state.sentRole = true
                    writer.writeText("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_\(Hashing.randomHex(8))\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"\(model)\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n")
                    writer.writeText("event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n")
                }
                if let text = delta["content"] as? String, !text.isEmpty,
                   let out = try? JSONSerialization.data(withJSONObject: ["type": "content_block_delta", "index": 0,
                                                                        "delta": ["type": "text_delta", "text": text]]),
                   let s = String(data: out, encoding: .utf8) {
                    writer.writeText("event: content_block_delta\ndata: \(s)\n\n")
                }
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty,
                   let out = try? JSONSerialization.data(withJSONObject: ["type": "content_block_delta", "index": 0,
                                                                        "delta": ["type": "thinking_delta", "thinking": reasoning]]),
                   let s = String(data: out, encoding: .utf8) {
                    writer.writeText("event: content_block_delta\ndata: \(s)\n\n")
                }
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                    writer.writeText("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")
                    writer.writeText("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(PromptEngine.anthropicStop(reason))\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":0}}\n\n")
                    writer.writeText("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
                }
            case .responses:
                let choice = ((chunk["choices"] as? [[String: Any]]) ?? []).first ?? [:]
                let delta = (choice["delta"] as? [String: Any]) ?? [:]
                guard (delta["content"] as? String)?.isEmpty == false
                        || (choice["finish_reason"] as? String)?.isEmpty == false else { return }
                ensureStart()
                if !state.sentRole {
                    state.sentRole = true
                    writer.writeText("event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_\(Hashing.randomHex(8))\",\"status\":\"in_progress\",\"model\":\"\(model)\",\"output\":[]}}\n\n")
                }
                if let text = delta["content"] as? String, !text.isEmpty,
                   let out = try? JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": text]),
                   let s = String(data: out, encoding: .utf8) {
                    writer.writeText("event: response.output_text.delta\ndata: \(s)\n\n")
                }
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                    writer.writeText("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_\(Hashing.randomHex(8))\",\"status\":\"completed\",\"model\":\"\(model)\"}}\n\n")
                    _ = reason
                }
            }
        }
        if !state.started { ensureStart() }
        writer.finish()
    }

    // MARK: - helpers

    private func resolveModel(_ requested: String) -> String {
        let cleaned = requested.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "auto" { return store.settings.defaultModel == "auto" ? "deepseek-v4-flash" : store.settings.defaultModel }
        // 去掉常见前缀，例如 openai/gpt-5.5
        if let slash = cleaned.lastIndex(of: "/") { return String(cleaned[cleaned.index(after: slash)...]) }
        return cleaned
    }

    private func pickAccount(skip: Int = 0) -> Account? {
        let pool = store.activeAccounts.filter { !$0.accessToken.isEmpty || !$0.refreshToken.isEmpty }
            .sorted { $0.credits > $1.credits }
        guard !pool.isEmpty else { return nil }
        let idx = rotation["cursor"] ?? 0
        rotation["cursor"] = (idx + 1 + skip) % pool.count
        return pool[(idx + skip) % pool.count]
    }

    private func conversationID(from body: [String: Any]) -> String {
        if let meta = body["metadata"] as? [String: Any],
           let id = meta["conversationId"] as? String, !id.isEmpty { return id }
        if let id = body["conversation_id"] as? String, !id.isEmpty { return id }
        var seed = ""
        for message in (body["messages"] as? [[String: Any]]) ?? [] {
            if (message["role"] as? String) == "user" {
                seed = PromptEngine.flatten(message["content"])
                if !seed.isEmpty { break }
            }
        }
        return seed.isEmpty ? Hashing.conversationID() : Hashing.uuidFrom(seed)
    }

    func reloadModels() async {
        guard let account = store.accounts.first(where: { !$0.disabled }) else { return }
        let list = await up.fetchModels(account: account)
        store.models = list
        store.log("模型目录已更新：\(list.count) 个", .ok)
    }

    nonisolated static var version: String { AppInfo.version }
}
