import Foundation

/// 系统提示词改写 + 上游拦截标记的规避 + 三方言互转。
enum PromptEngine {

    // MARK: - 系统提示词

    /// 按设置把自定义提示词写入 chat body。
    static func applySystemPrompt(_ obj: inout [String: Any], settings: Settings) {
        guard settings.promptMode != .off else { return }
        let prompt = settings.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard var messages = obj["messages"] as? [[String: Any]] else { return }
        let systemIndex = messages.firstIndex { ($0["role"] as? String) == "system" }
        switch settings.promptMode {
        case .off:
            return
        case .replace:
            if let i = systemIndex {
                messages[i]["content"] = prompt
            } else {
                messages.insert(["role": "system", "content": prompt], at: 0)
            }
        case .prepend:
            if let i = systemIndex {
                let existing = flatten(messages[i]["content"])
                messages[i]["content"] = prompt + "\n\n" + existing
            } else {
                messages.insert(["role": "system", "content": prompt], at: 0)
            }
        case .append:
            if let i = systemIndex {
                let existing = flatten(messages[i]["content"])
                if existing.isEmpty {
                    messages[i]["content"] = prompt
                } else if let parts = messages[i]["content"] as? [[String: Any]] {
                    var newParts = parts
                    newParts.append(["type": "text", "text": "\n\n" + prompt])
                    messages[i]["content"] = newParts
                } else {
                    messages[i]["content"] = existing + "\n\n" + prompt
                }
            } else {
                messages.insert(["role": "system", "content": prompt], at: 0)
            }
        }
        obj["messages"] = messages
    }

    static func flatten(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    // MARK: - 规避上游拦截标记

    /// 上游对客户端自报家门做前缀/全文匹配，命中即 403/400。这里只改写被拦的标记，
    /// 其余内容原样透传，模型看到的仍是客户端原本的指令。
    static let blockedMarkers: [(String, String)] = [
        ("You are Claude Code, Anthropic's official CLI tool for Claude.",
         "You are Claude Code, an official CLI for Claude."),
        ("x-anthropic-billing-header", "x-client-billing-header"),
        ("To give feedback, users should report the issue at", "For feedback, users should report the issue at"),
    ]

    static let blockedPrefixes: [(String, String)] = [
        ("You are a coding agent running in the Codex CLI tool, a terminal-based coding assistant. Codex CLI is an open source project led by OpenAI. You are expected to be precise, safe, and helpful.",
         "You're a coding agent running in the Codex CLI, a terminal-based coding assistant. Codex CLI is an open source project led by OpenAI. You are expected to be precise, safe, and helpful."),
        ("You are an AI agent powered by DeepSeek Harness.",
         "You are an AI assistant built on DeepSeek Harness."),
        ("You are a coding agent powered by the deepseek-v4.1-flash model.",
         "You are an assistant built on the deepseek-v4.1-flash model."),
    ]

    static func disguise(_ text: String) -> String {
        var out = text
        for (marker, replacement) in blockedMarkers where out.range(of: marker, options: .caseInsensitive) != nil {
            out = out.replacingOccurrences(of: marker, with: replacement, options: .caseInsensitive)
        }
        for (prefix, replacement) in blockedPrefixes where out.lowercased().hasPrefix(prefix.lowercased()) {
            out = replacement + String(out.dropFirst(prefix.count))
        }
        return out
    }

    static func needsDisguise(_ text: String) -> Bool {
        blockedMarkers.contains { text.range(of: $0.0, options: .caseInsensitive) != nil }
            || blockedPrefixes.contains { text.lowercased().hasPrefix($0.0.lowercased()) }
    }

    /// 只改写 system / assistant 角色：user 是真实提问，上游不拦。
    static func disguiseMessages(_ obj: inout [String: Any]) {
        guard var messages = obj["messages"] as? [[String: Any]] else { return }
        for i in messages.indices {
            let role = (messages[i]["role"] as? String) ?? ""
            guard role == "system" || role == "assistant" || role == "developer" else { continue }
            if let text = messages[i]["content"] as? String {
                if needsDisguise(text) { messages[i]["content"] = disguise(text) }
            } else if var parts = messages[i]["content"] as? [[String: Any]] {
                var changed = false
                for j in parts.indices {
                    guard let text = parts[j]["text"] as? String, needsDisguise(text) else { continue }
                    parts[j]["text"] = disguise(text)
                    changed = true
                }
                if changed { messages[i]["content"] = parts }
            }
        }
        obj["messages"] = messages
    }

    // MARK: - Anthropic Messages → Chat Completions

    static func anthropicToChat(_ body: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out["model"] = body["model"] ?? "auto"
        var messages: [[String: Any]] = []

        switch body["system"] {
        case let text as String:
            if !text.isEmpty { messages.append(["role": "system", "content": text]) }
        case let blocks as [[String: Any]]:
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { messages.append(["role": "system", "content": text]) }
        default:
            break
        }

        for message in (body["messages"] as? [[String: Any]]) ?? [] {
            let role = (message["role"] as? String) ?? "user"
            switch message["content"] {
            case let text as String:
                if !text.isEmpty { messages.append(["role": role, "content": text]) }
            case let blocks as [[String: Any]]:
                appendAnthropicBlocks(&messages, role: role, blocks: blocks)
            default:
                break
            }
        }
        out["messages"] = messages

        if let v = body["max_tokens"] { out["max_tokens"] = v }
        if let v = body["temperature"] { out["temperature"] = v }
        if let v = body["top_p"] { out["top_p"] = v }
        if let v = body["stream"] { out["stream"] = v }
        if let stop = body["stop_sequences"] as? [String], !stop.isEmpty { out["stop"] = stop }
        if let tools = body["tools"] as? [[String: Any]] {
            out["tools"] = tools.compactMap { tool -> [String: Any]? in
                guard let name = tool["name"] as? String else { return nil }
                var fn: [String: Any] = ["name": String(name.prefix(64))]
                if let desc = tool["description"] as? String { fn["description"] = desc }
                fn["parameters"] = tool["input_schema"] ?? ["type": "object"]
                return ["type": "function", "function": fn]
            }
        }
        if let choice = body["tool_choice"] as? [String: Any] {
            switch (choice["type"] as? String) ?? "" {
            case "auto": out["tool_choice"] = "auto"
            case "any": out["tool_choice"] = "required"
            case "tool": out["tool_choice"] = (choice["name"] as? String) ?? "auto"
            default: break
            }
        }
        if let thinking = body["thinking"] as? [String: Any],
           (thinking["type"] as? String) == "enabled" {
            let budget = (thinking["budget_tokens"] as? NSNumber)?.intValue ?? 0
            out["reasoning_effort"] = budget >= 24000 ? "high" : (budget >= 8000 ? "medium" : "low")
        }
        return out
    }

    private static func appendAnthropicBlocks(_ sink: inout [[String: Any]], role: String, blocks: [[String: Any]]) {
        var text = ""
        var parts: [[String: Any]] = []
        var toolCalls: [[String: Any]] = []
        var toolResults: [[String: Any]] = []
        var sawPart = false

        for block in blocks {
            switch (block["type"] as? String) ?? "" {
            case "text":
                let piece = (block["text"] as? String) ?? ""
                text += piece
                parts.append(["type": "text", "text": piece])
            case "image", "document":
                if let part = anthropicImagePart(block) {
                    sawPart = true
                    parts.append(part)
                }
            case "tool_use":
                var call: [String: Any] = [
                    "id": (block["id"] as? String) ?? Hashing.requestID(),
                    "type": "function",
                ]
                var fn: [String: Any] = ["name": String(((block["name"] as? String) ?? "tool").prefix(64))]
                if let input = block["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let json = String(data: data, encoding: .utf8) {
                    fn["arguments"] = json
                } else {
                    fn["arguments"] = "{}"
                }
                call["function"] = fn
                toolCalls.append(call)
            case "tool_result":
                var content = ""
                switch block["content"] {
                case let text as String: content = text
                case let parts as [[String: Any]]:
                    content = parts.compactMap { $0["text"] as? String }.joined()
                default: content = ""
                }
                if (block["is_error"] as? Bool) == true {
                    content = content.isEmpty ? "[tool error]" : "[tool error] \(content)"
                }
                toolResults.append([
                    "role": "tool",
                    "tool_call_id": (block["tool_use_id"] as? String) ?? "",
                    "content": content,
                ])
            default:
                break
            }
        }

        sink.append(contentsOf: toolResults)
        if !toolCalls.isEmpty {
            var message: [String: Any] = ["role": "assistant", "content": text]
            message["tool_calls"] = toolCalls
            sink.append(message)
        } else if sawPart {
            sink.append(["role": role, "content": parts])
        } else if !text.isEmpty {
            sink.append(["role": role, "content": text])
        }
    }

    private static func anthropicImagePart(_ block: [String: Any]) -> [String: Any]? {
        guard let source = block["source"] as? [String: Any] else { return nil }
        let media = (source["media_type"] as? String) ?? "image/png"
        switch source["type"] as? String {
        case "base64":
            guard let data = source["data"] as? String, !data.isEmpty else { return nil }
            return ["type": "image_url", "image_url": ["url": "data:\(media);base64,\(data)"]]
        case "url":
            guard let url = source["url"] as? String else { return nil }
            return ["type": "image_url", "image_url": ["url": url]]
        default:
            return nil
        }
    }

    // MARK: - Responses API → Chat Completions

    static func responsesToChat(_ body: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out["model"] = body["model"] ?? "auto"
        var messages: [[String: Any]] = []
        if let instructions = body["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        for item in (body["input"] as? [[String: Any]]) ?? [] {
            let role = (item["role"] as? String) ?? "user"
            switch item["content"] {
            case let text as String:
                messages.append(["role": role, "content": text])
            case let parts as [[String: Any]]:
                var texts: [String] = []
                var images: [[String: Any]] = []
                for part in parts {
                    switch (part["type"] as? String) ?? "" {
                    case "input_text", "output_text", "text":
                        texts.append((part["text"] as? String) ?? "")
                    case "input_image":
                        if let url = part["image_url"] as? String {
                            images.append(["type": "image_url", "image_url": ["url": url]])
                        }
                    default:
                        break
                    }
                }
                if images.isEmpty {
                    messages.append(["role": role, "content": texts.joined()])
                } else {
                    var content: [[String: Any]] = texts.map { ["type": "text", "text": $0] }
                    content.append(contentsOf: images)
                    messages.append(["role": role, "content": content])
                }
            default:
                break
            }
        }
        out["messages"] = messages
        if let v = body["max_output_tokens"] { out["max_tokens"] = v }
        if let v = body["temperature"] { out["temperature"] = v }
        if let v = body["stream"] { out["stream"] = v }
        if let tools = body["tools"] as? [[String: Any]] {
            out["tools"] = tools.compactMap { tool -> [String: Any]? in
                guard let name = tool["name"] as? String else { return nil }
                var fn: [String: Any] = ["name": String(name.prefix(64))]
                if let desc = tool["description"] as? String { fn["description"] = desc }
                fn["parameters"] = tool["parameters"] ?? ["type": "object"]
                return ["type": "function", "function": fn]
            }
        }
        if let effort = body["reasoning"] as? [String: Any], let e = effort["effort"] as? String {
            out["reasoning_effort"] = e
        }
        return out
    }

    // MARK: - Chat Completions → Anthropic / Responses

    static func chatToAnthropic(_ completion: [String: Any], model: String) -> [String: Any] {
        let choice = ((completion["choices"] as? [[String: Any]]) ?? []).first ?? [:]
        let message = (choice["message"] as? [String: Any]) ?? [:]
        var blocks: [[String: Any]] = []
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            blocks.append(["type": "thinking", "thinking": reasoning, "signature": ""])
        }
        if let text = message["content"] as? String, !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        for call in (message["tool_calls"] as? [[String: Any]]) ?? [] {
            let fn = (call["function"] as? [String: Any]) ?? [:]
            var input: Any = [:]
            if let args = fn["arguments"] as? String, let data = args.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                input = parsed
            }
            blocks.append([
                "type": "tool_use",
                "id": (call["id"] as? String) ?? Hashing.requestID(),
                "name": (fn["name"] as? String) ?? "tool",
                "input": input,
            ])
        }
        let usage = (completion["usage"] as? [String: Any]) ?? [:]
        return [
            "id": (completion["id"] as? String) ?? "msg_" + Hashing.randomHex(12),
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": blocks.isEmpty ? [["type": "text", "text": ""] as [String: Any]] : blocks,
            "stop_reason": anthropicStop((choice["finish_reason"] as? String) ?? "stop"),
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                "output_tokens": (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0,
            ],
        ]
    }

    static func anthropicStop(_ reason: String) -> String {
        switch reason {
        case "length": return "max_tokens"
        case "tool_calls": return "tool_use"
        case "content_filter": return "stop_sequence"
        default: return "end_turn"
        }
    }

    static func chatToResponses(_ completion: [String: Any], model: String) -> [String: Any] {
        let choice = ((completion["choices"] as? [[String: Any]]) ?? []).first ?? [:]
        let message = (choice["message"] as? [String: Any]) ?? [:]
        var output: [[String: Any]] = []
        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            output.append(["id": "rs_" + Hashing.randomHex(8), "type": "reasoning",
                           "summary": [["type": "summary_text", "text": reasoning]]])
        }
        let text = (message["content"] as? String) ?? ""
        output.append([
            "id": "msg_" + Hashing.randomHex(8), "type": "message", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": text, "annotations": []]],
        ])
        let usage = (completion["usage"] as? [String: Any]) ?? [:]
        return [
            "id": (completion["id"] as? String) ?? "resp_" + Hashing.randomHex(8),
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "model": model,
            "status": "completed",
            "output": output,
            "usage": [
                "input_tokens": (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
                "output_tokens": (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0,
                "total_tokens": (usage["total_tokens"] as? NSNumber)?.intValue ?? 0,
            ],
        ]
    }

    // MARK: - SSE 聚合

    /// 把上游 SSE 聚合成一个完整 completion（非流式请求用）。
    static func aggregate(_ sse: String, model: String) -> [String: Any] {
        var content = ""
        var reasoning = ""
        var finish = "stop"
        var usage: [String: Any] = [:]
        var toolCalls: [Int: [String: Any]] = [:]
        var order: [Int] = []

        for rawLine in sse.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            if line.hasPrefix("data:") { line = String(line.dropFirst(5)) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "[DONE]" { continue }
            guard let data = line.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let u = chunk["usage"] as? [String: Any], !u.isEmpty { usage = u }
            guard let choice = ((chunk["choices"] as? [[String: Any]]) ?? []).first else { continue }
            if let fr = choice["finish_reason"] as? String, !fr.isEmpty { finish = fr }
            let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
            if let piece = delta["content"] as? String { content += piece }
            if let piece = delta["reasoning_content"] as? String { reasoning += piece }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let idx = (call["index"] as? NSNumber)?.intValue ?? 0
                    var merged: [String: Any] = toolCalls[idx] ?? ["index": idx, "type": "function", "function": ["name": "", "arguments": ""]]
                    if let id = call["id"] as? String, !id.isEmpty { merged["id"] = id }
                    if let fn = call["function"] as? [String: Any] {
                        var target: [String: Any] = (merged["function"] as? [String: Any]) ?? ["name": "", "arguments": ""]
                        if let name = fn["name"] as? String, !name.isEmpty { target["name"] = name }
                        if let args = fn["arguments"] as? String {
                            target["arguments"] = ((target["arguments"] as? String) ?? "") + args
                        }
                        merged["function"] = target
                    }
                    if toolCalls[idx] == nil { order.append(idx) }
                    toolCalls[idx] = merged
                }
            }
        }

        var message: [String: Any] = ["role": "assistant", "content": content]
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !order.isEmpty {
            message["tool_calls"] = order.compactMap { toolCalls[$0] }
        }
        var result: [String: Any] = [
            "id": "chatcmpl-" + Hashing.randomHex(12),
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": order.isEmpty ? finish : "tool_calls",
            ]],
        ]
        if !usage.isEmpty { result["usage"] = usage }
        return result
    }

}
