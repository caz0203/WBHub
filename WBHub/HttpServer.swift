import Foundation
import Network

/// 极简 HTTP/1.1 服务：按请求行路由，支持 SSE 流式转发。
final class HttpServer: @unchecked Sendable {
    enum Method: String { case GET, POST, OPTIONS, HEAD, PUT, DELETE }

    struct Request {
        var method: Method
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            var headers = ["Content-Type": "application/json; charset=utf-8",
                           "Access-Control-Allow-Origin": "*"]
            let data = (try? JSONSerialization.data(withJSONObject: object))
                ?? Data("{}".utf8)
            headers["Content-Length"] = String(data.count)
            return Response(status: status, headers: headers, body: data)
        }

        static func error(_ message: String, status: Int, type: String = "invalid_request_error") -> Response {
            .json(["error": ["message": message, "type": type, "code": status]], status: status)
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wbhub.http", attributes: .concurrent)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    /// 把响应回写封装成对象，避免把逃逸闭包跨函数传递。
    final class Responder: @unchecked Sendable {
        private let handler: (Response) -> Void
        init(_ handler: @escaping (Response) -> Void) { self.handler = handler }
        func send(_ response: Response) { handler(response) }
    }

    var onRequest: (@Sendable (Request, Responder, StreamWriter) -> Void)?
    var onLog: (@Sendable (String, LogLine.Level) -> Void)?

    private var storedPort: Int = 0
    var port: Int { lock.lock(); defer { lock.unlock() }; return storedPort }

    func start(port: Int) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard port > 0, port < 65536, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "wbhub", code: 1, userInfo: [NSLocalizedDescriptionKey: "端口非法"])
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.storedPort = Int(listener.port?.rawValue ?? UInt16(port))
                self?.onLog?("监听 127.0.0.1:\(port) 已就绪", .ok)
            case .failed(let error):
                self?.onLog?("监听失败：\(error.localizedDescription)", .err)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        self.storedPort = port
    }

    func stop() {
        listener?.cancel()
        self.listener = nil
        lock.lock()
        let all = connections.values.map { $0 }
        connections.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    // MARK: - connection

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func close(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let chunk = chunk { buffer.append(chunk) }
            if let error = error {
                self.onLog?("连接错误：\(error.localizedDescription)", .warn)
                self.close(connection)
                return
            }
            if isComplete && buffer.isEmpty {
                self.close(connection)
                return
            }
            if let (request, consumed) = self.parse(buffer) {
                let remainder = buffer.count > consumed ? buffer.subdata(in: consumed..<buffer.count) : Data()
                self.handle(request, connection: connection, remainder: remainder)
            } else if isComplete {
                self.close(connection)
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func parse(_ buffer: Data) -> (Request, Int)? {
        guard let headerEnd = Self.findHeaderEnd(buffer) else { return nil }
        guard let rawHead = String(data: buffer.prefix(headerEnd), encoding: .utf8) else { return nil }
        let headText = rawHead.replacingOccurrences(of: "\r\n\r\n", with: "")
            .replacingOccurrences(of: "\n\n", with: "")
        var lines = headText.components(separatedBy: "\r\n")
        if lines.count == 1 { lines = headText.components(separatedBy: "\n") }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = Method(rawValue: String(parts[0]).uppercased()) ?? .GET
        var target = String(parts[1])
        if let schemeRange = target.range(of: "://") {
            let afterScheme = target[schemeRange.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                target = String(afterScheme[slash...])
            } else {
                target = "/"
            }
        }
        let path = target.components(separatedBy: "?").first ?? target
        var query: [String: String] = [:]
        if let q = target.components(separatedBy: "?").dropFirst().first {
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { query[String(kv[0])] = String(kv[1]) }
            }
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = headerEnd
        if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
            guard let (body, used) = Self.decodeChunked(buffer, from: bodyStart) else { return nil }
            return (Request(method: method, path: path, query: query, headers: headers, body: body),
                    bodyStart + used)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = contentLength > 0 ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
        return (Request(method: method, path: path, query: query, headers: headers, body: body),
                bodyStart + contentLength)
    }

    /// 解析 chunked 请求体；返回 (body, 消耗字节数)。数据不完整时返回 nil。
    private static func decodeChunked(_ data: Data, from start: Int) -> (Data, Int)? {
        var cursor = start
        var body = Data()
        while true {
            guard let lineEnd = indexOfCRLF(data, from: cursor) else { return nil }
            guard let sizeText = String(data: data[cursor..<lineEnd], encoding: .utf8)?
                .split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
                  let size = Int(sizeText, radix: 16) else { return nil }
            cursor = lineEnd + 2
            if size == 0 {
                // 末尾可能还有 trailer，找到空行结束
                if let trailerEnd = indexOfCRLF(data, from: cursor), trailerEnd == cursor {
                    return (body, cursor + 2 - start)
                }
                if let doubleEnd = data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.count) {
                    return (body, doubleEnd.upperBound - start)
                }
                return (body, cursor - start)
            }
            guard data.count >= cursor + size + 2 else { return nil }
            body.append(data[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }

    private static func indexOfCRLF(_ data: Data, from start: Int) -> Int? {
        guard start < data.count else { return nil }
        var i = start
        let bytes = [UInt8](data)
        while i + 1 < bytes.count {
            if bytes[i] == 13, bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    private static func findHeaderEnd(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 { return i + 4 }
            i += 1
        }
        var j = 0
        while j + 1 < bytes.count {
            if bytes[j] == 10, bytes[j + 1] == 10 { return j + 2 }
            j += 1
        }
        return nil
    }

    // MARK: - dispatch

    private func handle(_ request: Request, connection: NWConnection, remainder: Data) {
        if request.method == .OPTIONS {
            send(connection, Response(status: 204, headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
                "Access-Control-Allow-Headers": "*",
                "Content-Length": "0",
            ], body: Data()))
            return
        }
        guard let onRequest = onRequest else {
            send(connection, .error("server not ready", status: 503))
            return
        }
        let writer = StreamWriter(connection: connection)
        let responder = Responder { [weak self] response in self?.send(connection, response) }
        onRequest(request, responder, writer)
    }

    private func send(_ connection: NWConnection, _ response: Response) {
        var headers = response.headers
        headers["Connection"] = "close"
        headers.removeValue(forKey: "Transfer-Encoding")
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(response.body.count) }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 402: return "Payment Required"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    /// 流式响应写入器：先写 SSE 头，再逐块写 data 帧，最后关闭。
    final class StreamWriter: @unchecked Sendable {
        private let connection: NWConnection
        private var started = false
        private var closed = false
        private var pending: [Data] = []
        private let lock = NSLock()

        init(connection: NWConnection) {
            self.connection = connection
        }

        func start(status: Int, contentType: String) {
            lock.lock()
            if started { lock.unlock(); return }
            started = true
            let queued = pending
            pending.removeAll()
            lock.unlock()

            var head = "HTTP/1.1 \(status) \(HttpServer.reason(status))\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Cache-Control: no-cache\r\n"
            head += "Connection: keep-alive\r\n"
            head += "Access-Control-Allow-Origin: *\r\n"
            head += "Transfer-Encoding: chunked\r\n"
            head += "\r\n"
            connection.send(content: Data(head.utf8), contentContext: .defaultMessage, isComplete: false,
                            completion: .contentProcessed { _ in })
            for item in queued { sendChunk(item) }
        }

        func write(_ chunk: Data) {
            lock.lock()
            if !started { pending.append(chunk); lock.unlock(); return }
            if closed { lock.unlock(); return }
            lock.unlock()
            sendChunk(chunk)
        }

        private func sendChunk(_ chunk: Data) {
            var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
            framed.append(chunk)
            framed.append(Data("\r\n".utf8))
            connection.send(content: framed, contentContext: .defaultMessage, isComplete: false,
                            completion: .contentProcessed { _ in })
        }

        func writeText(_ text: String) {
            write(Data(text.utf8))
        }

        /// 无参启动：默认 SSE 头。
        func startSSE() { start(status: 200, contentType: "text/event-stream; charset=utf-8") }

        var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }

        func finish() {
            lock.lock()
            if closed { lock.unlock(); return }
            closed = true
            lock.unlock()
            if started {
                let tail = Data("0\r\n\r\n".utf8)
                connection.send(content: tail, contentContext: .defaultMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in
                    self?.connection.cancel()
                })
            } else {
                connection.cancel()
            }
        }

    }
}
