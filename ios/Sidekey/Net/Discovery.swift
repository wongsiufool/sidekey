import Foundation

/// 局域网里发现的一台电脑。
struct DiscoveredServer: Identifiable, Equatable {
    var id: String { name }
    let name: String     // 显示名 (Bonjour 实例名)
    let host: String     // 解析出的 IP
    let port: Int
}

/// 用 Bonjour 浏览 `_sidekey._tcp`, 自动发现局域网里在跑的电脑端。
@MainActor
final class Discovery: NSObject, ObservableObject {
    @Published private(set) var servers: [DiscoveredServer] = []

    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []   // 持有正在解析的服务, 防止被释放

    func start() {
        servers = []
        browser.delegate = self
        browser.searchForServices(ofType: "_sidekey._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        pending.removeAll()
    }

    private func upsert(_ s: DiscoveredServer) {
        if let i = servers.firstIndex(where: { $0.name == s.name }) { servers[i] = s }
        else { servers.append(s) }
    }

    /// 从 NetService 的 sockaddr 列表里取一个可用 IP。优先 IPv4(更普遍可连), 没有 v4 再用 IPv6 (审计 M-6)。
    /// IPv6 链路本地 fe80:: 跳过(需 zone id, 跨设备不可靠); 返回的是裸地址, URL 处再加方括号。
    private static func ipAddress(from addresses: [Data]) -> String? {
        var v6: String?
        for data in addresses {
            let parsed: (family: Int32, ip: String)? = data.withUnsafeBytes { raw in
                // 长度守卫: 先确保 blob 够大才解读 sockaddr, 防畸形数据越界读 (复审提的防御性硬化)。
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else { return nil }
                let fam = Int32(base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family)
                if fam == AF_INET {
                    guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                    var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    return (fam, String(cString: buf))
                } else if fam == AF_INET6 {
                    guard raw.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
                    var addr = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                    let s = String(cString: buf)
                    return s.lowercased().hasPrefix("fe80") ? nil : (fam, s)
                }
                return nil
            }
            guard let parsed else { continue }
            if parsed.family == AF_INET { return parsed.ip }   // 有 v4 直接用
            if v6 == nil { v6 = parsed.ip }                     // 记下第一个 v6 备用
        }
        return v6
    }
}

extension Discovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            self.pending.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        Task { @MainActor in self.servers.removeAll { $0.name == name } }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let port = sender.port
        let addrs = sender.addresses ?? []
        Task { @MainActor in
            if let ip = Discovery.ipAddress(from: addrs), port > 0 {
                self.upsert(DiscoveredServer(name: name, host: ip, port: port))
            }
            self.pending.removeAll { $0 == sender }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in self.pending.removeAll { $0 == sender } }
    }
}
