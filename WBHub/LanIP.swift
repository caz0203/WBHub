import Foundation

/// 局域网 IPv4 探测：取 en0（Wi-Fi）等接口上的私有地址。
/// 不可用时退回上一次缓存值，避免 UI 抖动。
enum LanIP {
    private static let lock = NSLock()
    private static var cached: String?

    static func refresh() {
        let ip = detect()
        lock.lock()
        if let ip = ip { cached = ip }
        lock.unlock()
    }

    static func current() -> String? {
        let ip = detect()
        if let ip = ip {
            lock.lock(); cached = ip; lock.unlock()
            return ip
        }
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 遍历网络接口，优先 en0，其次其它非回环私有地址
    private static func detect() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        var candidates: [(name: String, ip: String)] = []
        var ptr = first
        while true {
            let ifa = ptr.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if isPrivate(ip) && ip != "127.0.0.1" {
                        candidates.append((name, ip))
                    }
                }
            }
            guard let next = ifa.ifa_next else { break }
            ptr = next
        }

        // en0 (Wi-Fi) 优先
        if let wifi = candidates.first(where: { $0.name == "en0" }) { return wifi.ip }
        if let en = candidates.first(where: { $0.name.hasPrefix("en") }) { return en.ip }
        return candidates.first?.ip
    }

    private static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}
