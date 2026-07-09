import Foundation
import UIKit
import CryptoKit
import Security

/// 从电脑捕获(学习)到的按键。
struct CapturedKey: Equatable {
    var code: String
    var mods: [String]
}

/// 一次连接所用的完整目标配置。判断「编辑后目标是否真的变了」要用它 ——
/// 只比 computer.id 会漏掉「同一台电脑改了 IP / 端口 / 令牌 / 指纹」, 导致按键仍发往旧 socket (审计 H-1)。
struct ConnectionConfig: Equatable {
    var host: String
    var port: Int
    var token: String
    var fingerprint: String
}

/// 一个 agent (Claude Code / Codex 等) 当前的运行状态。
enum AgentState: String { case busy, ready, error, offline }

/// 电脑端推来的某个 agent 的状态快照。
struct AgentStatus: Equatable {
    var state: AgentState
    var project: String?
}

/// 线程安全地存「本次连接期望的证书指纹」: 主线程(connect)写、URLSession 委托读。
final class CertPin: @unchecked Sendable {
    private let lock = NSLock()
    private var fp: String?
    func set(_ v: String?) { lock.lock(); fp = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return fp }
}

/// 线程安全的一次性标志: 证书委托(委托队列)置位、主线程读取一次后清掉。用于把「指纹 pin 拒绝」
/// 准确地传给随后的连接失败分类(否则 URLSession 只报 -999 cancelled, 无法区分是不是证书不符)。
final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let r = v; v = false; return r }
}

/// 线程安全地存「本次连接的目标电脑 id」: 主线程(doConnect)写、URLSession 委托(TLS 握手中)同步读。
/// 让 TOFU 学到的指纹能绑定到「发起这次握手的那台电脑」, 而不是回调跑时碰巧选中的电脑 (审计复审 #2)。
final class LockedUUID: @unchecked Sendable {
    private let lock = NSLock()
    private var v: UUID?
    func set(_ x: UUID?) { lock.lock(); v = x; lock.unlock() }
    func get() -> UUID? { lock.lock(); defer { lock.unlock() }; return v }
}

/// 记录「当前这次 TLS 握手」的归属: 发起它的 task、连接代次、目标电脑 id。
/// 供 task 级 TLS 委托把 TOFU 指纹精确安到「发起本次握手的电脑」; 用户切到别的电脑后,
/// 旧握手的迟到 challenge 因 task 不符(或消费时代次已推进)被丢弃, 杜绝把 A 的指纹安到 B (审计复审 #4)。
final class LockedHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private var taskID: ObjectIdentifier?
    private var gen = 0
    private var computerID: UUID?
    func set(taskID: ObjectIdentifier, gen: Int, computerID: UUID?) {
        lock.lock(); self.taskID = taskID; self.gen = gen; self.computerID = computerID; lock.unlock()
    }
    /// 仅当传入的 task 正是当前记录的握手 task 时返回其归属(代次+电脑); 否则(已是别的握手)返回 nil。
    func match(_ id: ObjectIdentifier) -> (gen: Int, computerID: UUID?)? {
        lock.lock(); defer { lock.unlock() }
        guard taskID == id else { return nil }
        return (gen, computerID)
    }
}

/// TOFU 首连学到的证书指纹 + 它属于哪台电脑。带上 id 是为了: ①两台不同电脑用同一证书也能各自触发(值不同);
/// ②切换电脑时不会把 A 的指纹安到 B 上(消费方按 id 核对)。审计复审 #1/#2。
struct LearnedFingerprint: Equatable {
    let computerID: UUID?
    let fp: String
}

/// 和电脑小助手之间的 WebSocket 连接 (wss/TLS)。负责把按键事件发过去, 并在断线时自动重连。
@MainActor
final class SidekeyClient: NSObject, ObservableObject {
    /// 失败原因分类 (审计 H-3): 把各种底层错误归成用户看得懂、能据此行动的几类,
    /// 而不是统一压成「连接失败」。每类带短标题(药丸)、详细说明(banner)和「该重试还是该重新配对」。
    enum FailureKind: Equatable {
        case address    // 找不到 / 连不上电脑 (地址错或助手没开)
        case tls        // 证书与记录不符 (pin 失败 / 可能 MITM)
        case token      // 配对令牌失效 / 不正确
        case timeout    // 长时间无响应
        case network    // 其他网络中断
        case send       // 已连但按键没发出去

        var shortTitle: String {
            switch self {
            case .address: return String(localized: "连不上电脑")
            case .tls:     return String(localized: "证书不符")
            case .token:   return String(localized: "配对已失效")
            case .timeout: return String(localized: "连接超时")
            case .network: return String(localized: "连接中断")
            case .send:    return String(localized: "发送失败")
            }
        }
        var detail: String {
            switch self {
            case .address: return String(localized: "找不到这台电脑, 或它没在监听。确认电脑端 Sidekey 助手在运行、和手机连同一个 Wi-Fi, 且 IP/端口填对了。")
            case .tls:     return String(localized: "电脑的安全证书和上次记录的不一致 —— 可能是电脑端重置过证书, 也可能网络被人插手。请重新扫码配对以更新证书指纹。")
            case .token:   return String(localized: "配对令牌已失效或不正确。请重新扫码配对这台电脑。")
            case .timeout: return String(localized: "连接长时间没有响应。确认电脑端助手在运行、网络通畅后再重试。")
            case .network: return String(localized: "和电脑的连接中断了。检查 Wi-Fi 后重试, 稍后也会自动重连。")
            case .send:    return String(localized: "刚才有按键没能发出去, 连接可能不稳定 —— 正在自动重连, 稍等。")
            }
        }
        /// true = 建议「重新扫码配对」(令牌/证书类, 重试无用); false = 建议「重试」(网络类)。
        var needsRepair: Bool { self == .token || self == .tls }
    }

    enum Status: Equatable {
        case disconnected, connecting, connected
        case failed(FailureKind)
    }

    @Published private(set) var status: Status = .disconnected
    @Published var host: String = UserDefaults.standard.string(forKey: "sidekey.host") ?? ""
    @Published var port: String = UserDefaults.standard.string(forKey: "sidekey.port") ?? "8765"
    // 当前(手填连接)令牌优先取 Keychain, 取不到再回退旧的明文 UserDefaults(随后 doConnect 会迁进 Keychain)。
    @Published var token: String = KeychainToken.get("current")
        ?? UserDefaults.standard.string(forKey: "sidekey.token") ?? ""
    @Published var capturing = false
    @Published var captured: CapturedKey?
    /// 电脑端推来的各 agent 状态 (键: "claude" / "codex")。用于状态灯。
    @Published var agentStatuses: [String: AgentStatus] = [:]
    /// 电脑端推来的「当前活跃 agent」(最近在用的那个); 状态灯自动跟随它。
    @Published var activeAgent: String?
    /// 当前连接 / 正在连接的目标电脑 id (键实际发往哪台)。切换/删除电脑时用来对齐, 避免漂移。
    @Published private(set) var connectedComputerID: UUID?
    /// 当前连接所用的完整配置 (host/port/token/指纹)。用于判断「编辑同一台电脑改了地址/令牌」时要不要重连 (审计 H-1)。
    private(set) var connectedConfig: ConnectionConfig?
    /// 服务端是否已获「辅助功能」授权 (macOS)。false = 已连接但按键会被系统拦掉。鉴权后由 ready 消息更新。
    @Published private(set) var serverAXAuthorized = true
    /// TOFU: 手填连接(无指纹)首次握手时看到的服务端证书指纹 + 它属于哪台电脑; UI 据此固定到该电脑, 之后转严格 pin。
    /// 每次 doConnect 会先清成 nil(一次性事件), 否则同一指纹再学一次时 onChange 不触发, 持久化/核对被静默跳过 (审计复审 #1)。
    @Published var learnedFingerprint: LearnedFingerprint?

    private let pin = CertPin()                        // 本次连接期望的服务端证书指纹 (wss pin)
    private let tlsRejected = OneShotFlag()            // 证书 pin 不符的一次性标志 → 失败分类成 .tls
    private let connectingTarget = LockedUUID()        // (兜底) 本次握手目标电脑 id, 供 session 级 TLS 委托同步读; task 级走下面的精确归属
    private let handshakeOrigin = LockedHandshake()     // (精确) 发起本次握手的 task+代次+电脑, 供 task 级 TLS 委托绑定 TOFU 指纹归属 (审计复审 #4)
    var statusDeep = false                             // 状态灯「深度检测」开关; 随 hello 发给服务端
    private var task: URLSessionWebSocketTask?
    /// 连接代次: 每次 teardown 推进一次。旧 task 被取消后晚到的 receive/didClose 回调,
    /// 用捕获的代次比对当前值, 不一致就丢弃, 避免污染刚建立的新连接 (审计: 连接回调竞态)。
    private(set) var connectionGeneration = 0
    private lazy var session: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    private var shouldReconnect = false               // 是否应自动重连 (手动断开/令牌错时为 false)
    private var attempts = 0                           // 重连退避计数
    private var reconnectTask: Task<Void, Never>?
    private var inBackground = false                   // 进后台时暂停重连, 避免锁屏后台空转耗电

    private var heartbeatTask: Task<Void, Never>?      // 心跳: 周期发 ping, 检测半死连接
    private var lastReceived: TimeInterval = 0         // 上次收到任何消息的 systemUptime
    private let heartbeatInterval: TimeInterval = 25   // 每 25s 发一次 ping
    private let deadAfter: TimeInterval = 60           // 超过 60s 没任何消息 → 判定连接已死, 重连
    private var handshakeTask: Task<Void, Never>?      // 握手看门狗: 连上 socket 但迟迟收不到 ready 就超时重连
    private let handshakeTimeout: TimeInterval = 10    // socket 打开后这么久还没 ready(鉴权完成) → 判超时
    private let maxIncomingMessageSize = 1 << 20       // 收包上限 1MB, 防超大消息打爆内存

    override init() {
        super.init()
        // App 回到前台时, 若该连而没连, 立即重连 (锁屏/切后台会断)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // 进后台: 暂停重连 (锁屏/切后台时不要后台空转重连耗电)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appEnteredBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    /// 为 wss URL 处理 host: IPv6 字面量(含「:」)要用方括号 `wss://[fd00::1]:8765`; v4 / 已带括号原样。供单测 (审计 M-6)。
    nonisolated static func bracketedHost(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespaces)
        return (h.contains(":") && !h.hasPrefix("[")) ? "[\(h)]" : h
    }

    // MARK: - 连接 / 断开
    func connect() {
        shouldReconnect = true
        attempts = 0
        reconnectTask?.cancel(); reconnectTask = nil   // 取消挂起的退避重连, 免得它和本次手动连接打架 (审计: 连接竞态)
        doConnect()
    }

    /// 连接到指定电脑 (用它自己的地址/端口/令牌)。多电脑切换 / 启动自动连 / 编辑保存后都走这里。
    /// 连接协调器: 以「目标电脑 id + 完整配置」为准 —— 同一台、同一套配置且连接还活着就不打断;
    /// 只要换了电脑、或同一台改了 IP/端口/令牌/指纹, 就拆掉旧 socket 重连 (修审计 H-1)。
    /// force=true 时绕过幂等短路, 强制重连一次 (用于「重新检测」: 重走握手拿最新 AX 能力)。
    func connect(to computer: Computer, force: Bool = false) {
        let target = ConnectionConfig(host: computer.host, port: computer.port,
                                      token: computer.token, fingerprint: computer.fingerprint)
        let live = (status == .connected || status == .connecting)
        if !force, connectedComputerID == computer.id, connectedConfig == target, live {
            return   // 目标与配置都没变、连接还在 → 不重连, 避免无谓打断
        }
        connectedComputerID = computer.id
        connectedConfig = target
        host = computer.host
        port = String(computer.port)
        token = computer.token
        pin.set(computer.fingerprint.isEmpty ? nil : computer.fingerprint)
        connect()
    }

    /// TOFU 学到指纹后立即用于本连接的后续重连(不必等下次 connect(to:)), 让同一会话内的重连也受 pin 保护。
    func adoptFingerprint(_ fp: String) {
        guard !fp.isEmpty else { return }
        pin.set(fp)
        // 同步进 connectedConfig: 否则下次 reconcile 会把「刚学到指纹」误判成配置变更而无谓重连。
        connectedConfig?.fingerprint = fp
    }

    /// 扫码/粘贴配对码后调用: 填好地址/端口/令牌并连接。
    func applyPairing(_ p: PairingPayload) {
        connectedComputerID = nil          // 配对码不绑定某台已存电脑
        connectedConfig = nil              // 随后保存成电脑再 connect(to:) 会带上完整配置
        if let h = p.hosts.first { host = h }
        port = String(p.port)
        token = p.token
        let f = p.fp ?? ""
        pin.set(f.isEmpty ? nil : f)
        connect()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        status = .disconnected
        connectedComputerID = nil
        connectedConfig = nil
        serverAXAuthorized = true
    }

    /// 切换「深度检测」开关: 存下来; 若已连则重连以重发 hello(带新值)。
    func applyStatusDeep(_ on: Bool) {
        guard on != statusDeep else { return }
        statusDeep = on
        switch status {
        case .connected, .connecting: doConnect()
        default: break
        }
    }

    private func doConnect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        let hostForURL = Self.bracketedHost(h)   // IPv6 字面量加方括号 (审计 M-6)
        guard !h.isEmpty, let p = Int(port), let url = URL(string: "wss://\(hostForURL):\(p)") else {
            // 地址/端口根本拼不出合法 URL: 配置问题, 自动重连没意义, 等用户改地址。
            status = .failed(.address); connectedComputerID = nil
            shouldReconnect = false; return
        }
        UserDefaults.standard.set(h, forKey: "sidekey.host")
        UserDefaults.standard.set(port, forKey: "sidekey.port")
        // 令牌存 Keychain(敏感), 并清掉旧的明文 UserDefaults。
        KeychainToken.set(token, for: "current")
        UserDefaults.standard.removeObject(forKey: "sidekey.token")
        teardown()
        connectingTarget.set(connectedComputerID)   // 记下这次握手的目标电脑, 供 TLS 委托绑定 TOFU 指纹归属
        learnedFingerprint = nil                     // 清掉上次的一次性事件, 让相同指纹再学一次也能触发 onChange (审计复审 #1)
        serverAXAuthorized = true        // 新连接先假定 OK, 等服务端 ready 消息再更新
        status = .connecting
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = maxIncomingMessageSize   // 收包上限, 防超大消息打爆内存
        task = t
        handshakeOrigin.set(taskID: ObjectIdentifier(t), gen: connectionGeneration, computerID: connectedComputerID)  // 绑定本次握手到发起它的 task+代次+电脑, 供 TLS 委托精确归属 TOFU 指纹 (审计复审 #4)
        lastReceived = ProcessInfo.processInfo.systemUptime
        t.resume()
        listen()
        startHeartbeat()
        startHandshakeTimeout()          // socket 开了却收不到 ready 会一直卡 .connecting, 看门狗兜底 (审计复审 #3)
        sendJSON(["v": 1, "type": "hello", "name": UIDevice.current.name, "token": token, "statusDeep": statusDeep])
    }

    /// 握手看门狗 (审计复审 #3): M-1 后只有收到 ready 才转 .connected; 若对端完成 TLS+WS 升级却始终不发 ready
    /// (假/挂死的服务端、错连了别的 WS、升级后就死掉但没断 TCP),心跳的 dead-check 只在 .connected 跑, 会永远卡 .connecting。
    /// 这里独立计时: 到点还在 .connecting 就按超时断开重连。
    private func startHandshakeTimeout() {
        handshakeTask?.cancel()
        let limit = handshakeTimeout
        handshakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard case .connecting = self.status else { return }   // 已经 ready/失败了就不管
            self.teardown()
            self.fail(.timeout)
        }
    }

    private func stopHandshakeTimeout() {
        handshakeTask?.cancel()
        handshakeTask = nil
    }

    private func teardown() {
        connectionGeneration &+= 1   // 作废旧连接代次: 此后旧 task 的 receive/didClose 回调都被 gen/identity 守卫丢弃 (审计: 连接竞态)
        stopHeartbeat()
        stopHandshakeTimeout()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        moveInFlight = false; pendingDX = 0; pendingDY = 0   // 清掉触控板背压残量, 重连不跳
        scrollInFlight = false; pendingScrollDX = 0; pendingScrollDY = 0
        failPendingResults("disconnected")                   // 连接没了, 挂起的粘贴回执立即判失败(听写文本保留)
    }

    /// 统一的失败入口 (审计 H-3): 设分类后的失败态, 并决定要不要继续自动重连。
    /// 证书不符 / 令牌失效 → 停止自动重连(重试无用, 还可能是 MITM), 等用户重新配对;
    /// 其余网络类 → 照常退避重连。
    private func fail(_ kind: FailureKind) {
        status = .failed(kind)
        if kind == .tls || kind == .token {
            shouldReconnect = false
            reconnectTask?.cancel(); reconnectTask = nil
        } else if shouldReconnect {
            scheduleReconnect()
        }
    }

    /// 把 URLSession 的底层错误归类成 FailureKind。先看「证书 pin 拒绝」一次性标志(我们主动取消时
    /// 系统只报 -999, 无法据 code 区分), 再按 NSURLError 域的码归类。
    /// nonisolated: 只读 tlsRejected(线程安全)与 NSError, 便于在 receive 回调里先算好分类、不捕获非 Sendable 的 error。
    nonisolated private func classify(_ error: Error) -> FailureKind {
        if tlsRejected.take() { return .tls }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .network }
        switch ns.code {
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return .tls
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorResourceUnavailable:
            return .address
        default:
            return .network
        }
    }

    private func scheduleReconnect() {
        // 后台暂停重连(省电); 前台无限重试 —— 退避封顶 30s, 这样电脑端恢复后总能在 ~30s 内自动连回。
        guard shouldReconnect, !inBackground else { return }
        reconnectTask?.cancel()
        // 指数退避 + 抖动 + 30s 封顶: 1,2,4,8,16,30…(±最多 50% 抖动), 避免网络抖动时齐刷刷重连。
        let baseDelay = min(30.0, pow(2.0, Double(min(attempts, 5))))
        let delay = baseDelay + Double.random(in: 0...(baseDelay * 0.5))
        attempts += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.shouldReconnect, !self.inBackground else { return }
            switch self.status {
            case .connected, .connecting: return
            default: self.doConnect()
            }
        }
    }

    @objc private nonisolated func appBecameActive() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.inBackground = false
            guard self.shouldReconnect else { return }
            switch self.status {
            case .connected:
                // socket 在后台可能已半死却没收到回调; 回前台重新计时并重启心跳, 让它能探测到。
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                self.startHeartbeat()
            case .connecting:
                self.startHeartbeat()        // 心跳循环里 guard .connected, 连上后才真正开始 ping
            default:
                self.attempts = 0
                self.doConnect()
            }
        }
    }

    @objc private nonisolated func appEnteredBackground() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 进后台: 停掉重连定时器与心跳, 别在锁屏/后台空转耗电。保留 shouldReconnect 意图, 回前台再连。
            self.inBackground = true
            self.reconnectTask?.cancel(); self.reconnectTask = nil
            self.stopHeartbeat()
        }
    }

    // MARK: - 心跳 (检测半死连接)
    private func startHeartbeat() {
        stopHeartbeat()
        let interval = heartbeatInterval, dead = deadAfter
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard case .connected = self.status else { continue }   // 没连上不发心跳
                let idle = ProcessInfo.processInfo.systemUptime - self.lastReceived
                if idle > dead {
                    // 超时没收到任何消息(含 pong/状态推送) → 判定半死连接, 主动断开重连。
                    self.teardown()
                    self.fail(.timeout)
                    return
                }
                self.sendJSON(["v": 1, "type": "ping"])
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - 发送
    func sendKey(_ cap: KeyCap) {
        var obj: [String: Any] = ["v": 1, "type": "key", "code": cap.code]
        if !cap.mods.isEmpty { obj["mods"] = cap.mods }
        sendJSON(obj)
    }

    func sendText(_ text: String) {
        sendJSON(["v": 1, "type": "text", "text": text])
    }

    /// 发 N 次 Shift+Tab —— Claude Code 用它循环切换权限模式。逐次留 0.15s 间隔, 保证 TUI 逐个识别。
    /// (Claude Code 没有「⌘⇧M + 数字」选模式的机制, 真实机制就是 Shift+Tab 循环。)
    func sendShiftTab(times: Int) {
        guard times > 0 else { return }
        for i in 0..<times {
            let fire: () -> Void = { [weak self] in self?.sendKey(KeyCap(label: "", code: "tab", mods: ["shift"])) }
            if i == 0 { fire() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15, execute: fire) }
        }
    }

    /// 设置 Claude Code Effort 档位: 用可靠的「粘贴 + 回车」通道发 `/effort <级别>` 斜杠命令。
    /// (服务端按消息顺序处理: 先完成粘贴, 再回车 —— 与现有斜杠命令键同一语义。)
    func sendEffort(_ level: EffortLevel) {
        sendPaste("/effort \(level.cliName)")
        sendKey(KeyCap(label: "", code: "enter"))
    }

    /// 把文字发给电脑, 电脑端用剪贴板粘贴打出来 (可靠插入中英文, 绕过输入法)。
    func sendPaste(_ text: String) {
        sendJSON(["v": 1, "type": "paste", "text": text])
    }

    // MARK: - 带回执的粘贴 (审计 M-5: 听写要知道电脑端到底打出来没有, 失败别丢文字)
    private var pendingResults: [Int: (Bool, String?) -> Void] = [:]
    private var nextReqId = 1

    /// 发一段粘贴并等待电脑端回执。completion(ok, errorCode) 保证在主线程被调用且仅一次:
    /// 成功 (true, nil) / 失败 (false, "ax"|"clipboard"|"inject") / 超时 (false, "timeout") / 未连接 (false, "disconnected")。
    func sendPasteTracked(_ text: String, timeout: TimeInterval = 4,
                          completion: @escaping (Bool, String?) -> Void) {
        guard case .connected = status else { completion(false, "disconnected"); return }
        let id = nextReqId; nextReqId &+= 1
        pendingResults[id] = completion
        sendJSON(["v": 1, "type": "paste", "text": text, "reqId": id])
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, let cb = self.pendingResults.removeValue(forKey: id) else { return }
            cb(false, "timeout")   // 超时没回执: 当失败处理, 让听写文本保留
        }
    }

    /// 断开/失败时让所有挂起的回执立刻收尾, 不必等各自超时。
    private func failPendingResults(_ code: String) {
        guard !pendingResults.isEmpty else { return }
        let cbs = Array(pendingResults.values)
        pendingResults.removeAll()
        for cb in cbs { cb(false, code) }
    }

    // MARK: - 触控板 / 鼠标
    private var moveInFlight = false        // 是否有一条 move 还没发完 (背压闸门)
    private var pendingDX = 0               // 攒着待发的合并位移
    private var pendingDY = 0

    /// 相对移动光标 (dx,dy 像素)。单指拖时高频调用。
    /// 合并待发位移 + 背压: 上一条发完才发下一条 —— 网络慢时自动把多帧合并成一条大位移,
    /// 从源头消除高频小包在 wss/TLS 下排队成批涌入、再被服务端逐条施加造成的「台阶/卡顿」。
    func sendMouseMove(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        pendingDX += dx; pendingDY += dy
        flushMouseMove()
    }

    private func flushMouseMove() {
        guard !moveInFlight, pendingDX != 0 || pendingDY != 0, let task else { return }
        let dx = pendingDX, dy = pendingDY
        pendingDX = 0; pendingDY = 0
        guard let data = try? JSONSerialization.data(withJSONObject:
                ["v": 1, "type": "mouse", "action": "move", "dx": dx, "dy": dy]),
              let str = String(data: data, encoding: .utf8) else { return }
        moveInFlight = true
        task.send(.string(str)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.moveInFlight = false
                if error == nil { self.flushMouseMove() }       // 发完→冲下一批 (背压)
                else { self.pendingDX = 0; self.pendingDY = 0 }  // 失败→丢残量, 免得重连后跳一下
            }
        }
    }
    /// 单击 (button: "left" / "right")。
    func sendMouseClick(button: String) {
        sendJSON(["v": 1, "type": "mouse", "action": "click", "button": button])
    }
    private var scrollInFlight = false
    private var pendingScrollDX = 0
    private var pendingScrollDY = 0

    /// 滚动 (dx,dy 像素级增量)。和指针移动同样的合并+背压: 上一条发完才发下一条,
    /// 网络慢自动把多帧合并成一条, 配合服务端 macOS 像素级滚动 → 顺滑不顿。
    func sendMouseScroll(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        pendingScrollDX += dx; pendingScrollDY += dy
        flushMouseScroll()
    }

    private func flushMouseScroll() {
        guard !scrollInFlight, pendingScrollDX != 0 || pendingScrollDY != 0, let task else { return }
        let dx = pendingScrollDX, dy = pendingScrollDY
        pendingScrollDX = 0; pendingScrollDY = 0
        guard let data = try? JSONSerialization.data(withJSONObject:
                ["v": 1, "type": "mouse", "action": "scroll", "dx": dx, "dy": dy]),
              let str = String(data: data, encoding: .utf8) else { return }
        scrollInFlight = true
        task.send(.string(str)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.scrollInFlight = false
                if error == nil { self.flushMouseScroll() }
                else { self.pendingScrollDX = 0; self.pendingScrollDY = 0 }
            }
        }
    }
    /// 按下不放 (拖拽用)。
    func sendMouseDown(button: String) {
        sendJSON(["v": 1, "type": "mouse", "action": "down", "button": button])
    }
    /// 松开。
    func sendMouseUp(button: String) {
        sendJSON(["v": 1, "type": "mouse", "action": "up", "button": button])
    }

    /// 请求电脑进入"捕获模式": 接下来你在电脑键盘上按的键会被学习回来 (填进 captured)。
    func requestCapture() {
        captured = nil
        capturing = true
        sendJSON(["v": 1, "type": "capture_start"])
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { [weak self] error in
            guard error != nil else { return }
            // 发送失败 = 连接多半已断。回流到可见状态(不再只 print 到控制台, 审计 H-3),
            // 让用户知道「按键没发出去」而不是对着死连接干点。
            Task { @MainActor in self?.noteSendFailure() }
        }
    }

    /// 离散按键/文本发送失败的处理: 若此刻仍显示「已连接」, 翻成失败态并自动重连。
    /// (高频的触控板 move/scroll 走各自的背压通道、自愈丢残量, 不在这里报错, 免得打扰。)
    private func noteSendFailure() {
        guard case .connected = status else { return }
        teardown()
        fail(.send)
    }

    // MARK: - 接收
    private func listen() {
        let gen = connectionGeneration            // 捕获本次连接代次; 回调里据此判断是否仍是当前连接
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                let kind = self.classify(error)       // 先在回调里归类(nonisolated), 避免把非 Sendable 的 error 带进 Task
                Task { @MainActor in
                    guard gen == self.connectionGeneration else { return }   // 旧连接晚到的失败回调, 丢弃 (审计: 连接竞态)
                    self.fail(kind)                                          // 归类后再决定重连 (审计 H-3)
                }
            case .success(let message):
                var text: String? = nil                                      // 只把 String(Sendable) 带进 Task, 不带非 Sendable 的 Message
                if case .string(let s) = message { text = s }
                Task { @MainActor in
                    guard gen == self.connectionGeneration else { return }   // 旧连接晚到的消息, 丢弃 (审计: 连接竞态)
                    self.lastReceived = ProcessInfo.processInfo.systemUptime  // 任何消息都算「活着」
                    if let text, let data = text.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handleIncoming(obj)
                    }
                    self.listen()
                }
            }
        }
    }

    nonisolated private func handleIncoming(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "hello_ack":
            // 收到握手回应 ≠ 鉴权通过。此时仍是「连接中」, 要等 ready 才标绿 ——
            // 否则坏令牌会先转绿再失败, UI 误导且会短暂放行按键 (修审计 M-1)。
            // 注意: 不在这里重置退避计数(只有 ready 才重置)。否则只回 hello_ack 却迟迟不发 ready 的对端
            // 会让退避每轮归零、退化成 ~1s 的紧密重连循环 (审计: Codex M-2)。
            Task { @MainActor in
                if case .failed = self.status {} else { self.status = .connecting }
            }
        case "ready":
            let ax = (obj["ax"] as? Bool) ?? true
            Task { @MainActor in
                self.stopHandshakeTimeout()   // 握手完成, 撤掉看门狗
                self.serverAXAuthorized = ax  // 鉴权后服务端报告能力: 辅助功能没授权时按键无效
                self.status = .connected      // 鉴权完成, 此刻才算真连上
                self.attempts = 0
            }
        case "error":
            let raw = obj["message"] as? String ?? ""
            // 令牌不符 / 需要鉴权 → 归为「配对已失效」(fail 内会停掉自动重连, 等用户重新配对)。
            let kind: FailureKind = (raw == "bad token" || raw == "auth required") ? .token : .network
            Task { @MainActor in self.fail(kind) }
        case "result":
            // 粘贴回执 (审计 M-5): 按 reqId 找到对应的等待方, 告诉它电脑端到底打出来没有。
            let rid = obj["reqId"] as? Int
            let ok = (obj["ok"] as? Bool) ?? false
            let err = obj["error"] as? String
            Task { @MainActor in
                guard let rid, let cb = self.pendingResults.removeValue(forKey: rid) else { return }
                cb(ok, err)
            }
        case "captured":
            let code = obj["code"] as? String ?? ""
            let mods = (obj["mods"] as? [String]) ?? []
            Task { @MainActor in
                self.captured = CapturedKey(code: code, mods: mods)
                self.capturing = false
            }
        case "capture_failed":
            Task { @MainActor in self.capturing = false }
        case "agent_status":
            let raw = (obj["agents"] as? [String: Any]) ?? [:]
            var parsed: [String: AgentStatus] = [:]
            for (key, value) in raw {
                guard let d = value as? [String: Any] else { continue }
                let st = AgentState(rawValue: (d["state"] as? String) ?? "") ?? .offline
                parsed[key] = AgentStatus(state: st, project: d["project"] as? String)
            }
            let active = obj["active"] as? String
            let ax = obj["ax"] as? Bool      // 周期推送顺带带 AX 授权; 运行中被撤销也能及时提示
            Task { @MainActor in
                self.agentStatuses = parsed; self.activeAgent = active
                if let ax { self.serverAXAuthorized = ax }
            }
        default:
            break
        }
    }
}

extension SidekeyClient: URLSessionWebSocketDelegate {
    /// session 级委托: connection-level challenge 的通用入口。无 task → TOFU 归属退回 connectingTarget 兜底(与旧行为一致);
    /// 仅当下面 task 级方法未接管 server trust 时才会走到, 保证任何情况下都不会连不上 (防御性保留)。
    nonisolated func urlSession(_ session: URLSession,
                                didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleServerTrust(challenge, taskID: nil, completionHandler: completionHandler)
    }

    /// task 级委托: 有 task → 按「发起本次握手的 task」精确归属 TOFU 指纹。切到别的电脑后, 旧握手的迟到 challenge
    /// 因 task 不符 / 消费时代次已推进被丢弃, 杜绝把 A 的证书指纹错安到 B (根治审计复审 #4 的切换竞态)。
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleServerTrust(challenge, taskID: ObjectIdentifier(task), completionHandler: completionHandler)
    }

    /// wss 自签名证书校验 + TOFU 指纹归属。有指纹→严格 pin(防 MITM); 无指纹→首用即信并把指纹交给 UI 固定到发起本次握手的电脑。
    /// taskID != nil 走精确归属(handshakeOrigin 按 task 匹配 + 代次校验); nil 走 connectingTarget 兜底。
    nonisolated private func handleServerTrust(_ challenge: URLAuthenticationChallenge, taskID: ObjectIdentifier?,
                                               completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard let leaf = chain.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let der = SecCertificateCopyData(leaf) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        if let expected = pin.get(), !expected.isEmpty {
            // 已知指纹: 严格 pin —— 不符即拒, 防中间人。
            if fp.caseInsensitiveCompare(expected) == .orderedSame {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                tlsRejected.set()   // 标记: 随后的连接失败要分类成「证书不符」(审计 H-3)
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // 无指纹(手填连接): TOFU 首用即信 —— 接受证书, 并把指纹交给 UI 固定到这台电脑, 之后转严格 pin。
            // 首连仍有一次被冒充的窗口(扫码配对没有此窗口, 一开始就带指纹)。
            // 归属精确化(审计复审 #4):
            //  · task 级: 必须匹配「发起本次握手的 task」。匹配不上 = 旧握手的迟到 challenge(用户已切到别的电脑),
            //    完成这次(僵尸)握手但绝不学指纹 —— 杜绝把 A 的证书指纹安到 B。
            //  · session 级(无 task): 退回 connectingTarget 兜底(旧行为), 只保证不断连。
            completionHandler(.useCredential, URLCredential(trust: trust))
            let owner: UUID?
            let originGen: Int?
            if let taskID {
                guard let o = handshakeOrigin.match(taskID) else { return }   // 迟到的旧握手 task → 丢弃, 不学
                owner = o.computerID; originGen = o.gen
            } else {
                owner = connectingTarget.get(); originGen = nil              // 仅 session 级无 task 时兜底
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let originGen, !self.isCurrentGeneration(originGen) { return }   // 已切换/重连 → 旧握手作废, 丢弃
                self.learnedFingerprint = LearnedFingerprint(computerID: owner, fp: fp)
            }
        }
    }

    /// 某次握手发起时捕获的连接代次是否仍是当前代次。切换电脑/重连会推进代次, 使旧握手的迟到 TOFU 结果判废。
    /// 抽成方法便于单测锁定这个不变量 (完整 TLS 时序仍需真机回归)。
    func isCurrentGeneration(_ gen: Int) -> Bool { gen == connectionGeneration }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        // 不在 WS 一打开就标「已连接」: 打开 ≠ 对方是 Sidekey 服务端、≠ 鉴权通过。
        // 等服务端回 hello_ack 再标绿 (见 handleIncoming 的 "hello_ack")。
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        let closedId = ObjectIdentifier(webSocketTask)   // ObjectIdentifier 是 Sendable, 可安全带进 Task
        Task { @MainActor in
            // 只认当前 task 的关闭; 旧 task(编辑/切换/删除电脑后被取消)的 didClose 不得清掉新连接 (审计: 连接竞态)
            guard let current = self.task, ObjectIdentifier(current) == closedId else { return }
            self.task = nil
            if case .failed = self.status {} else { self.status = .disconnected }
            if self.shouldReconnect { self.scheduleReconnect() }
        }
    }
}
