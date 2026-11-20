import Foundation

/// 轻量 HTTP 客户端：上游请求、SSE 流、信封解包、错误分类。
final class Net: @unchecked Sendable {
    static let shared = Net()

    private let session: URLSession
    private let streaming: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: cfg)

        let scfg = URLSessionConfiguration.ephemeral
        scfg.timeoutIntervalForRequest = 30
        scfg.timeoutIntervalForResource = 3600
        scfg.httpShouldSetCookies = false
        scfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        streaming = URLSession(configuration: scfg)
    }

    struct Response {
        var status: Int
        var data: Data
        var headers: [AnyHashable: Any]
        var text: String { String(data: data, encoding: .utf8) ?? "" }
    }

    func send(_ url: String, method: String = "POST", headers: [String: String], body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Response {
        guard let u = URL(string: url) else {
            throw Wire.UpstreamError(kind: .transport, status: 0, message: "bad url \(url)")
        }
        var request = URLRequest(url: u)
        request.httpMethod = method
        for (k, v) in headers where !v.isEmpty { request.setValue(v, forHTTPHeaderField: k) }
        if let body = body { request.httpBody = body }
        if let timeout = timeout { request.timeoutInterval = timeout }
        do {
            let (data, resp) = try await session.data(for: request)
            let http = resp as? HTTPURLResponse
            return Response(status: http?.statusCode ?? 0, data: data, headers: http?.allHeaderFields ?? [:])
        } catch {
            throw Wire.UpstreamError(kind: .transport, status: 0, message: error.localizedDescription)
        }
    }

    /// SSE：逐行回调。返回上游状态码；非 2xx 时把 body 作为错误抛出。
    func stream(_ url: String, headers: [String: String], body: Data, onLine: @escaping @Sendable (String) -> Void) async throws -> Int {
        guard let u = URL(string: url) else {
            throw Wire.UpstreamError(kind: .transport, status: 0, message: "bad url")
        }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        for (k, v) in headers where !v.isEmpty { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        request.timeoutInterval = 3600
        let (bytes, resp) = try await streaming.bytes(for: request)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status >= 400 {
            var collected = Data()
            for try await b in bytes {
                collected.append(b)
                if collected.count > 8192 { break }
            }
            let text = String(data: collected, encoding: .utf8) ?? ""
            throw Wire.UpstreamError(kind: Wire.classify(status: status, body: text), status: status,
                                     message: Wire.displayError(text) ?? text.prefix(300).description)
        }
        var buffer = Data()
        for try await byte in bytes {
            if byte == 0x0A {
                if let line = String(data: buffer, encoding: .utf8) {
                    onLine(line.hasSuffix("\r") ? String(line.dropLast()) : line)
                }
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
        return status
    }

    // MARK: - 信封

    struct Envelope {
        var code: Int
        var msg: String
        var data: Any?
        var raw: Data
    }

    static func envelope(_ resp: Response) -> Envelope? {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any] else { return nil }
        let code = (obj["code"] as? NSNumber)?.intValue ?? 0
        let msg = (obj["msg"] as? String) ?? ""
        return Envelope(code: code == 0 && resp.status >= 400 ? resp.status : code, msg: msg, data: obj["data"], raw: resp.data)
    }

    /// 发 JSON 并解信封；code != 0 视为业务失败。
    func json(_ url: String, method: String = "POST", headers: [String: String], body: Any? = nil) async throws -> Envelope {
        var data: Data? = nil
        if let body = body {
            data = try? JSONSerialization.data(withJSONObject: body)
        }
        if data == nil && method == "POST" { data = Data("{}".utf8) }
        let resp = try await send(url, method: method, headers: headers, body: data)
        guard resp.status < 400 else {
            throw Wire.UpstreamError(kind: Wire.classify(status: resp.status, body: resp.text),
                                     status: resp.status,
                                     message: Wire.displayError(resp.text) ?? resp.text.prefix(300).description)
        }
        guard let env = Self.envelope(resp) else {
            throw Wire.UpstreamError(kind: .server, status: resp.status, message: "非 JSON 响应: \(resp.text.prefix(160))")
        }
        return env
    }
}
