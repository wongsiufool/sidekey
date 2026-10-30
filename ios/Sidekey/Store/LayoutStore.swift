import Foundation
import Security
import CryptoKit

/// 把配对令牌(敏感)存进 Keychain, 而不是明文 UserDefaults JSON。
/// `AfterFirstUnlockThisDeviceOnly`: 不进 iCloud / iTunes 备份、仅本机、首次解锁后可读(后台重连也取得到)。
/// account = 电脑 id 字符串 (或 "current" 表示手填连接的当前令牌)。
enum KeychainToken {
    private static let service = "com.kaihongchen.sidekey.token"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 写入 (覆盖式)。返回是否成功 —— 调用方据此决定是否还把明文留在 blob 里兜底。
    /// 「先删后加」: 删除成功 (或本来就没有) 才写新项; **删除失败时旧项会留下**, 此时直接返回 false (不写新项), 由调用方保留明文兜底,
    /// 加载时「主存档里有明文就以明文为准」, 旧项不会盖过它。写新项失败 (删除已成功) 则没有旧值残留。
    /// 若日后改成 SecItemUpdate 优化, 失败可能留下陈旧值 —— 不要这么改。
    @discardableResult
    static func set(_ token: String, for account: String) -> Bool {
        #if DEBUG
        if let r = faultSet?(account) { return r }
        #endif
        guard let data = token.data(using: .utf8) else { return false }
        let del = SecItemDelete(base(account) as CFDictionary)  // 先删后加, 保证覆盖
        #if DEBUG
        if del == errSecSuccess { observe?("keychain-set-deleted:" + account) }     // 「旧项已删、新项还没写」这个检查点
        #endif
        guard del == errSecSuccess || del == errSecItemNotFound else { return false }   // 旧项删不掉就不能写新项 (否则旧值会盖过新令牌); 调用方保留明文兜底
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #if DEBUG
        if ok { observe?("keychain-set:" + account) }
        #endif
        return ok
    }

    /// 读取结果三态: 不存在 / 读取失败 (暂时读不了, 例如设备锁定、系统错误) / 读到了。
    /// 「读不到」不等于「用户清空了」—— 只有明确的用户清空意图才能触发删除。
    enum ReadResult: Equatable { case found(String), notFound, failed(OSStatus) }
    #if DEBUG
    /// 测试用故障注入 (仅 DEBUG): 让某个账户的读取 / 删除失败。
    nonisolated(unsafe) static var faultRead: ((String) -> ReadResult?)?
    nonisolated(unsafe) static var faultDelete: ((String) -> Bool?)?
    nonisolated(unsafe) static var faultAccounts: ((String) -> [String]??)?
    nonisolated(unsafe) static var faultSet: ((String) -> Bool?)?
    /// 测试用: 每次真的写入 / 删除 Keychain 项之后回调 (逐个写入点回放用)。
    nonisolated(unsafe) static var observe: ((String) -> Void)?
    #endif
    static func read(_ account: String) -> ReadResult {
        #if DEBUG
        if let r = faultRead?(account) { return r }
        #endif
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return .notFound }
        guard st == errSecSuccess else { return .failed(st) }
        guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
        return .found(s)
    }

    static func get(_ account: String) -> String? {
        if case .found(let s) = read(account) { return s }
        return nil
    }

    /// 列出以 `prefix` 开头的账户名。**枚举失败返回 nil** (≠ 没有账户: 那是空数组), 调用方据此保留清理任务。
    static func accounts(prefix: String) -> [String]? {
        #if DEBUG
        if let r = faultAccounts?(prefix) { return r }
        #endif
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return [] }
        guard st == errSecSuccess, let rows = out as? [[String: Any]] else { return nil }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
    }
    /// 删掉某台电脑的所有令牌账户 (镜像账户 `<id>` + 各修订 `<id>@<rev>`); 全部成功 (含枚举成功) 才返回 true。
    @discardableResult
    static func deleteAll(id: String) -> Bool {
        var ok = delete(id)
        guard let list = accounts(prefix: id + "@") else { return false }
        for a in list { ok = delete(a) && ok }
        return ok
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        #if DEBUG
        if let r = faultDelete?(account) { return r }
        #endif
        let st = SecItemDelete(base(account) as CFDictionary)
        #if DEBUG
        if st == errSecSuccess { observe?("keychain-delete:" + account) }
        #endif
        return st == errSecSuccess || st == errSecItemNotFound
    }
}

/// 整个 App 的存储: 多台电脑, 每台有自己的模式集, 每个模式含若干层。
/// 布局是「网格坐标」模型 (KeyLayer.columns + KeyCap.col/row/colSpan/rowSpan)。
/// 改动即时存到 UserDefaults。当前选中的「电脑 + 模式」决定主键盘显示哪套布局;
/// 对外的 `layers` / `layer(_:)` / 键的增删改等都作用在「当前模式」上。
@MainActor
final class LayoutStore: ObservableObject {
    @Published private(set) var computers: [Computer]
    @Published var currentComputerID: UUID
    @Published var currentModeID: UUID

    /// 主存档 (v5) 读不出来时的恢复状态 (§6.4 第 5 条): 不覆盖原始数据, 提示用户导出或选择继续。
    struct Recovery { let rawData: Data }
    @Published private(set) var recovery: Recovery?
    /// 有修改没能写进存档 (超出读取上限等): 内存保留修改、界面照常按新数据工作, 存档仍是最后一次成功保存的内容 (v1.8 §6.4 第 7 条)。
    /// 只在保存成功或「放弃修改」后清除。
    @Published private(set) var hasUnsavedChanges = false
    /// 放弃修改后递增: 各窗口据此把当前电脑 / 模式 / 页按 §5 修正。
    @Published private(set) var discardGeneration = 0
    /// 上次运行时有修改没能保存就被关闭了: 本次启动提示一次。
    @Published private(set) var previousSessionLostChanges = false
    nonisolated static let unsavedMarkerKey = "sidekey.unsaved.v1"
    /// 「上次有修改没能保存」的待确认提示: 启动时由未保存标记转成, 用户确认后才清 (提示还没显示就再次启动也不会丢)。
    nonisolated static let unsavedNoticeKey = "sidekey.unsaved.notice.v1"
    /// 待清理的电脑凭证 (删电脑后 Keychain 里的令牌): 只在存档里确实没有这台电脑、且某次保存成功之后才删; 删失败保留, 之后每次保存成功和启动时重试。
    nonisolated static let credentialCleanupKey = "sidekey.credCleanup.v1"
    /// 凭证记录 (和主存档配对): 每条带「它所配对的那份主存档字节的完整 SHA-256」+ 这份存档里
    /// ① 「用户明确清空了令牌」的电脑 (墓碑: 加载时忽略 Keychain, 旧项没删掉也不复活) ② 每台电脑的**稳定凭证引用** (令牌在 Keychain 的 `<id>@<rev>`)。
    /// 加载时只采用与当前主存档字节匹配的那一条; 先写记录、后写主存档, 崩溃在中间时主存档仍是旧的, 匹配到旧记录 (旧引用指向的旧令牌项还在)。
    nonisolated static let clearedTokensKey = "sidekey.credRecord.v3"
    /// 凭证修订的回收任务: 提交后要清掉的旧修订项; 删除或枚举失败就留着, 下次保存成功 / 启动时重试。
    nonisolated static let revCleanupKey = "sidekey.credRevCleanup.v1"
    /// 恢复期间不写主存档, 否则用默认数据覆盖掉原始数据。
    private var persistBlocked = false

    // MARK: 大屏键位 (§6, M2) —— 读写逻辑见 LayoutStore+Large.swift; 这几个状态只由 LayoutStore 及其扩展改。
    /// 已生成的大屏键位, 按「电脑 + 模式」索引。没有记录 = 还没生成。
    @Published var large: [LargeKey: LargeLayout] = [:]
    /// 最近一次成功写入的大屏键位 (启动时为磁盘上的): 「放弃修改」恢复用, 也用于崩溃安全的写入顺序。
    var committedLarge: [LargeKey: LargeLayout] = [:]
    /// `sidekey.large.v1` 读不出来时的恢复状态: 原始数据已备份, 在用户处理前不写这个 key (主存档照常保存)。
    @Published var largeRecovery: Recovery?
    var largeBlocked: Bool { largeRecovery != nil }

    let defaults: UserDefaults

    /// 读不出来的 v5 原始数据的备份 key 前缀。每次损坏都留一份 (相同内容不重复), 后缀 .1 .2 ...: 第二次损坏不会盖掉第一次。
    nonisolated static let corruptBackupPrefix = "sidekey.app.v5.corrupt"
    static func corruptBackupKeys(in defaults: UserDefaults, prefix: String = corruptBackupPrefix) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
    /// 备份一份损坏的原始数据, 返回备份用的 key (已有相同内容的备份就复用)。
    @discardableResult
    static func backUpCorrupt(_ data: Data, in defaults: UserDefaults, prefix: String = corruptBackupPrefix) -> String {
        let keys = corruptBackupKeys(in: defaults, prefix: prefix)
        if let same = keys.first(where: { defaults.data(forKey: $0) == data }) { return same }
        var n = keys.count + 1
        while defaults.object(forKey: "\(prefix).\(n)") != nil { n += 1 }
        let key = "\(prefix).\(n)"
        defaults.set(data, forKey: key)
        return key
    }
    nonisolated static let storeKey = "sidekey.app.v5"        // v5: 模式集存储 schema (内置模式清单见 BuiltinModes.makeAll())
    private static let legacyV4Key = "sidekey.app.v4"     // v4: 网格布局模型 (迁移: 保留电脑/连接, 模式重种为内置两套)
    private static let legacyV3Key = "sidekey.app.v3"     // v3: 行流式布局 (迁移时只保留电脑/模式, 布局重置)
    private static let legacyV3BackupKey = "sidekey.app.v3.backup"   // 迁移前的 v3 原始存档备份, 布局重置不等于丢原始数据 (审计: Codex High-2)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pendingCredentialIDs = Set((defaults.stringArray(forKey: LayoutStore.credentialCleanupKey) ?? []).compactMap(UUID.init(uuidString:)))
        pendingRevCleanup = Set((defaults.stringArray(forKey: LayoutStore.revCleanupKey) ?? []).compactMap(UUID.init(uuidString:)))
        let (p, corruptRaw, unreadable, refs) = LayoutStore.load(from: defaults)
        tokenUnreadable = unreadable
        tokenRefs = refs
        unreadableTokenCount = unreadable.count          // init 里不触发 didSet
        if let corruptRaw {
            persistBlocked = true
            recovery = Recovery(rawData: corruptRaw)
        }
        computers = p.computers
        currentComputerID = p.currentComputerID
        currentModeID = p.currentModeID
        loadLarge()                                    // 大屏键位 (独立 key, §6.4): 读不出来就进它自己的恢复流程, 不覆盖原始数据
        // 容错: 修复无效的当前选择。
        if !computers.contains(where: { $0.id == currentComputerID }) {
            currentComputerID = computers[0].id
        }
        let modes = computers.first { $0.id == currentComputerID }?.modes ?? []
        if !modes.contains(where: { $0.id == currentModeID }) {
            currentModeID = modes.first?.id ?? currentModeID
        }
        committedLarge = large
        committed = (computers, currentComputerID, currentModeID, tokenUnreadable)     // 「放弃修改」的恢复点: 启动迁移 / 第一次重新编码之前读到的状态
        if defaults.bool(forKey: LayoutStore.unsavedMarkerKey) {      // 上次有修改没存上就被关闭: 转成待确认提示 (确认后才清, 提示没显示就再启动也不丢)
            defaults.set(true, forKey: LayoutStore.unsavedNoticeKey)
            defaults.removeObject(forKey: LayoutStore.unsavedMarkerKey)
        }
        previousSessionLostChanges = defaults.bool(forKey: LayoutStore.unsavedNoticeKey)
        // 内置布局升级: 旧存档版本落后 → 升级内置模式。
        if (p.builtinVersion ?? 0) < BuiltinModes.version {
            upgradeBuiltinLayoutsIfSafe(from: p.builtinVersion ?? 0)   // 非破坏: 仅升级未编辑的旧出厂布局
            applyV10ModeOverhaul(from: p.builtinVersion ?? 0)          // v10: 强制统一阵容 (有意破坏性)
            addMissingBuiltins()  // 补齐缺失内置 (vibecoding键盘模式); 内部已 persist (写入最新版本号)
        } else {
            persist()
        }
        if !hasUnsavedChanges { runCredentialCleanup(); runRevCleanup() }   // 补做上次没清掉的凭证 / 旧修订
    }

    // MARK: - 当前选中的 电脑 / 模式
    var currentComputer: Computer? { computers.first { $0.id == currentComputerID } }
    var currentMode: Mode? { currentComputer?.modes.first { $0.id == currentModeID } }

    /// 记录用户对令牌的意图: 设置了新令牌 = 不再「未知」; 令牌被设成空 = 明确清空 (与「读不出来」区分开)。
    private func noteTokenIntent(id: UUID, token: String) {
        if token.isEmpty { userClearedTokens.insert(id) } else { userClearedTokens.remove(id) }      // 「未知」状态只在提交成功时才解除 (放弃修改要能恢复)
    }

    private var computerIndex: Int? { computers.firstIndex { $0.id == currentComputerID } }
    private func modeIndex(inComputer ci: Int) -> Int? {
        computers[ci].modes.firstIndex { $0.id == currentModeID }
    }

    /// 切换当前电脑: 顺带恢复它上次用的模式。
    @discardableResult
    func selectComputer(_ id: UUID) -> Bool {
        guard let target = computers.first(where: { $0.id == id }) else { return false }
        currentComputerID = id
        currentModeID = target.lastModeID ?? target.modes.first?.id ?? currentModeID
        persist()
        return true
    }

    /// 切换当前模式 (限本电脑内), 并记住为该电脑的「上次模式」。
    @discardableResult
    func selectMode(_ id: UUID) -> Bool {
        guard let ci = computerIndex,
              computers[ci].modes.contains(where: { $0.id == id }) else { return false }
        currentModeID = id
        computers[ci].lastModeID = id
        persist()
        return true
    }

    // MARK: - 顶栏快捷条: 置顶
    /// 顶栏快捷切换条要显示的电脑: 用户置顶的那些 (保持 computers 原序)。
    var pinnedComputers: [Computer] { computers.filter { $0.isPinned } }

    /// 切换某台电脑的「置顶」(是否出现在顶栏快捷条)。
    func togglePin(_ id: UUID) {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return }
        computers[i].pinned = !(computers[i].pinned ?? false)
        persist()
    }

    // MARK: - 电脑的增删改
    /// 返回修改是否已生效 (保存失败时修改仍保留在内存, 见 `hasUnsavedChanges`)。
    @discardableResult
    func addComputer(_ c: Computer) -> Bool {
        noteTokenIntent(id: c.id, token: c.token)
        computers.append(c)
        persist()
        return true
    }

    @discardableResult
    func upsertComputer(name: String, host: String, port: Int, token: String, fingerprint: String = "") -> UUID {
        let nm = name.trimmingCharacters(in: .whitespaces)
        if let i = computers.firstIndex(where: { !host.isEmpty && $0.host == host }) {
            computers[i].port = port
            noteTokenIntent(id: computers[i].id, token: token)
            computers[i].token = token
            computers[i].fingerprint = fingerprint
            if computers[i].name.isEmpty { computers[i].name = nm.isEmpty ? host : nm }
            persist(); return computers[i].id
        }
        if let i = computers.firstIndex(where: { $0.id == currentComputerID }),
           computers[i].host.isEmpty {
            computers[i].host = host
            computers[i].port = port
            noteTokenIntent(id: computers[i].id, token: token)
            computers[i].token = token
            computers[i].fingerprint = fingerprint
            computers[i].name = nm.isEmpty ? host : nm
            persist(); return computers[i].id
        }
        let c = Computer.make(name: nm.isEmpty ? host : nm, host: host, port: port, token: token, fingerprint: fingerprint)
        noteTokenIntent(id: c.id, token: token)
        computers.append(c)
        persist(); return c.id
    }

    @discardableResult
    func renameComputer(id: UUID, to name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = computers.firstIndex(where: { $0.id == id }) else { return false }
        computers[i].name = t
        persist()
        return true
    }

    @discardableResult
    func updateComputerConnection(id: UUID, host: String, port: Int, token: String, fingerprint: String = "") -> Bool {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return false }
        computers[i].host = host
        computers[i].port = port
        noteTokenIntent(id: computers[i].id, token: token)
        computers[i].token = token
        computers[i].fingerprint = fingerprint
        persist()
        return true
    }

    /// 编辑电脑: 名称 + 连接信息合成**一次**提交 (一起保存, 一起未保存)。`name` 为空则保留原名。
    @discardableResult
    func updateComputer(id: UUID, name: String, host: String, port: Int, token: String, fingerprint: String) -> Bool {
        updateComputer(id: id, name: name, host: host, port: port, tokenEdit: token.isEmpty ? .clear : .set(token), fingerprint: fingerprint)
    }

    /// 表单用: 令牌显式传「保留 / 设置 / 清空」。`.keep` 不动 store 里的当前值 (令牌未知、或表单打开期间已被重读恢复, 都不会被没动过的空框覆盖 / 误删)。
    @discardableResult
    func updateComputer(id: UUID, name: String, host: String, port: Int, tokenEdit: TokenEdit, fingerprint: String) -> Bool {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return false }
        let t = name.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { computers[i].name = t }
        computers[i].host = host
        computers[i].port = port
        switch tokenEdit {
        case .keep: break
        case .set(let v): noteTokenIntent(id: id, token: v); computers[i].token = v
        case .clear: noteTokenIntent(id: id, token: ""); computers[i].token = ""
        }
        computers[i].fingerprint = fingerprint
        persist()
        return true
    }

    /// TOFU: 把手填连接首次握手学到的证书指纹固定到这台电脑 —— 仅当它当前还没有指纹时
    /// (不覆盖扫码/已固定的指纹; 之后该机即转入严格 pin, 再被冒充会被拒)。
    func learnFingerprint(_ fp: String, for id: UUID) {
        guard !fp.isEmpty,
              let i = computers.firstIndex(where: { $0.id == id }),
              computers[i].fingerprint.isEmpty else { return }
        computers[i].fingerprint = fp
        persist()
    }

    @discardableResult
    func deleteComputer(id: UUID) -> Bool {
        guard computers.count > 1, let idx = computers.firstIndex(where: { $0.id == id }) else { return false }
        computers.removeAll { $0.id == id }
        if currentComputerID == id {
            currentComputerID = computers[0].id
            currentModeID = computers[0].lastModeID ?? computers[0].modes.first?.id ?? currentModeID
        }
        _ = idx
        for k in large.keys where k.computer == id { large[k] = nil }        // 这台电脑的大屏键位一起删
        // 凭证只记下「待清理」, 真正删除在某次保存成功之后、按最终提交的数据决定 (保存失败期间 Keychain 一点不动)。
        pendingCredentialIDs.insert(id)
        saveCredentialCleanup()
        persist()
        return true
    }

    // MARK: - 模式的增删改 (作用在当前电脑)
    @discardableResult
    func addMode(named rawName: String) -> UUID? {
        guard let ci = computerIndex else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let mode = Mode.makeDefault(name: name.isEmpty ? "模式\(computers[ci].modes.count + 1)" : name)
        computers[ci].modes.append(mode)
        persist()
        return mode.id
    }

    func renameMode(id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let ci = computerIndex,
              let mi = computers[ci].modes.firstIndex(where: { $0.id == id }) else { return }
        computers[ci].modes[mi].name = name
        persist()
    }

    func deleteMode(id: UUID) {
        guard let ci = computerIndex, computers[ci].modes.count > 1 else { return }
        computers[ci].modes.removeAll { $0.id == id }
        large[LargeKey(computer: computers[ci].id, mode: id)] = nil          // §6.3: 删除模式 = 两套键位一起删
        if currentModeID == id, let first = computers[ci].modes.first {
            currentModeID = first.id
            computers[ci].lastModeID = first.id
        }
        persist()
    }

    @discardableResult
    func duplicateMode(id: UUID, toComputer targetID: UUID? = nil) -> UUID? {
        guard let ci = computerIndex,
              let mode = computers[ci].modes.first(where: { $0.id == id }) else { return nil }
        let destID = targetID ?? currentComputerID
        guard let di = computers.firstIndex(where: { $0.id == destID }) else { return nil }
        var copy = LayoutStore.freshCopy(of: mode)
        copy.name = mode.name + " 副本"
        computers[di].modes.append(copy)
        // §6.3: 两套键位一起复制; 大屏键位还没生成就不复制 (副本第一次进内屏时再生成)
        if let src = large[LargeKey(computer: computers[ci].id, mode: id)] {
            large[LargeKey(computer: destID, mode: copy.id)] = LayoutStore.freshCopy(of: src)
        }
        persist()
        return copy.id
    }

    /// 深拷贝一套大屏键位: 每个键 (含鼠标键) 的 id 换新, 页 id 不变 (跳转键的 targetLayer 指的是页 id, 引用不断)。
    static func freshCopy(of l: LargeLayout) -> LargeLayout {
        var c = l
        c.layers = l.layers.map { layer in var x = layer; x.keys = layer.keys.map { var k = $0; k.id = UUID(); return k }; return x }
        c.mouseButtons = l.mouseButtons.map { var k = $0; k.id = UUID(); return k }
        return c
    }

    /// 深拷贝一个模式: 模式 id 与每个键的 id 都换新 (避免跨模式撞 id)。
    private static func freshCopy(of mode: Mode) -> Mode {
        var m = mode
        m.id = UUID()
        m.layers = mode.layers.map { layer in
            var l = layer
            l.keys = layer.keys.map { var c = $0; c.id = UUID(); return c }
            return l
        }
        return m
    }

    // MARK: - 查询
    /// 当前电脑 + 当前模式的原键位 (只给还没改成显式目标的旧调用方当默认值; 窗口级代码一律传 `LayoutTarget`)。
    var currentTarget: LayoutTarget { LayoutTarget(computer: currentComputerID, mode: currentModeID, set: .original) }
    var layers: [KeyLayer] { currentMode?.layers ?? DefaultLayout.makeDefault() }
    func layer(_ id: String) -> KeyLayer? { layers.first { $0.id == id } }

    func computer(_ id: UUID) -> Computer? { computers.first { $0.id == id } }
    func mode(computer: UUID, mode: UUID) -> Mode? { self.computer(computer)?.modes.first { $0.id == mode } }
    func layers(computer: UUID, mode: UUID) -> [KeyLayer] {
        self.mode(computer: computer, mode: mode)?.layers ?? DefaultLayout.makeDefault()
    }
    /// 按明确目标取页。目标不存在、或大屏键位还没生成时返回空数组 (调用方据此判断, 不拿默认数据冒充)。
    func layers(in target: LayoutTarget?) -> [KeyLayer] {
        let t = target ?? currentTarget
        switch t.set {
        case .original: return mode(computer: t.computer, mode: t.mode)?.layers ?? []
        case .large: return large[LargeKey(computer: t.computer, mode: t.mode)]?.layers ?? []
        }
    }
    func layer(_ id: String, in target: LayoutTarget?) -> KeyLayer? { layers(in: target).first { $0.id == id } }

    /// 改一套键位的页并保存 (保存失败时修改仍保留在内存)。`target` 为 nil = 当前模式的原键位。
    /// 只作用于这一套 (§6.3): 原键位的修改不碰大屏键位, 反之亦然。大屏键位还没生成时不做任何事, 返回 false。
    @discardableResult
    private func mutateLayers(_ target: LayoutTarget?, _ body: (inout [KeyLayer]) -> Void) -> Bool {
        let t = target ?? currentTarget
        guard let ci = computers.firstIndex(where: { $0.id == t.computer }),
              let mi = computers[ci].modes.firstIndex(where: { $0.id == t.mode }) else { return false }
        switch t.set {
        case .original:
            body(&computers[ci].modes[mi].layers)
        case .large:
            let key = LargeKey(computer: t.computer, mode: t.mode)
            guard var entry = large[key] else { return false }
            body(&entry.layers)
            entry.edited = true
            large[key] = entry
        }
        persist()
        return true
    }

    // MARK: - 网格占用工具
    // 按矩形相交判断占用 (不展开成格子编码): 旧数据里可能有超出范围的坐标 / 跨度 (例如 col = Int.max),
    // 键的右 / 下边界一律用 LayoutBounds.end 防溢出算, 不会崩, 也不会把不同的格子算成同一个。

    /// 键占的矩形 [c0, c1) × [r0, r1) (跨度 < 1 的旧数据按 1 算)。
    private static func rect(_ k: KeyCap) -> (c0: Int, c1: Int, r0: Int, r1: Int) {
        (k.col, LayoutBounds.end(k.col, k.colSpan), k.row, LayoutBounds.end(k.row, k.rowSpan))
    }

    /// 指定矩形区域在网格内、且不和别的键 (excluding 除外) 重叠。
    static func regionFree(in layer: KeyLayer, col: Int, row: Int,
                           colSpan: Int, rowSpan: Int, excluding: UUID?) -> Bool {
        guard col >= 0, row >= 0, colSpan >= 1, rowSpan >= 1,
              LayoutBounds.keyFits(KeyCap(label: "", col: col, row: row, colSpan: colSpan, rowSpan: rowSpan), columns: layer.columns)
        else { return false }                                       // 编辑接口超出合法范围就拒绝 (§6.4 第 5 条, 与读取校验同一套)
        let c1 = col + colSpan, r1 = row + rowSpan                  // 上面已校验在范围内, 不会溢出
        return !layer.keys.contains { k in
            guard k.id != excluding else { return false }
            let o = rect(k)
            return o.c0 < c1 && col < o.c1 && o.r0 < r1 && row < o.r1
        }
    }

    /// 找第一个能放下 colSpan×rowSpan 的空区域 (先行后列最靠前, 返回左上角); 整个合法范围内都放不下返回 nil。
    /// 最靠前的空位, 它的行一定是 0 或某个键的下边界 (否则还能再往上挪一行), 列同理是 0 或某个键的右边界;
    /// 所以只试这些候选位置, 就能覆盖全部合法行 (0 ... maxCoordinate − rowSpan), 不用逐行扫。
    private static func firstFreeRegion(in layer: KeyLayer, colSpan: Int, rowSpan: Int) -> (col: Int, row: Int)? {
        guard colSpan >= 1, rowSpan >= 1, layer.columns >= 1, colSpan <= layer.columns,
              rowSpan <= LayoutBounds.maxCoordinate else { return nil }
        let rects = layer.keys.map(rect)
        let maxRow = LayoutBounds.maxCoordinate - rowSpan, maxCol = layer.columns - colSpan
        let rows = Set([0] + rects.map(\.r1)).filter { (0...maxRow).contains($0) }.sorted()
        let cols = Set([0] + rects.map(\.c1)).filter { (0...maxCol).contains($0) }.sorted()
        for r in rows {
            let band = rects.filter { $0.r0 < r + rowSpan && r < $0.r1 }      // 和这一行带相交的键
            for c in cols where !band.contains(where: { $0.c0 < c + colSpan && c < $0.c1 }) { return (c, r) }
        }
        return nil
    }

    private static func firstFreeCell(in layer: KeyLayer) -> (col: Int, row: Int)? {
        firstFreeRegion(in: layer, colSpan: 1, rowSpan: 1)
    }

    // MARK: - 键的增删改 (当前模式)
    @discardableResult
    func updateKey(layerID: String, cap: KeyCap, in target: LayoutTarget? = nil) -> Bool {
        // 页或键已不存在 (例如放弃修改后编辑器还拿着旧数据): 不应用、不保存, 返回 false
        guard let l = layer(layerID, in: target), let old = l.keys.first(where: { $0.id == cap.id }) else { return false }
        // 改了位置 / 大小且新位置超出合法范围: 拒绝 (位置没动的旧数据照常可改其他属性)
        let moved = (old.col, old.row, old.colSpan, old.rowSpan) != (cap.col, cap.row, cap.colSpan, cap.rowSpan)
        guard !moved || LayoutBounds.keyFits(cap, columns: l.columns) else { return false }
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }),
                  let ki = layers[li].keys.firstIndex(where: { $0.id == cap.id }) else { return }
            layers[li].keys[ki] = cap
        }
        return true
    }

    /// 在第一个空格子放一个 1×1 新键, 返回它的 id (供编辑器选中)。
    @discardableResult
    func addKey(layerID: String, in target: LayoutTarget? = nil) -> UUID? {
        var newID: UUID?
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            guard let pos = LayoutStore.firstFreeCell(in: layers[li]) else { return }   // 合法范围内没有空位: 不加
            let cap = KeyCap(label: "新键", code: "space", col: pos.col, row: pos.row)
            guard LayoutBounds.keyFits(cap, columns: layers[li].columns) else { return }
            newID = cap.id
            layers[li].keys.append(cap)
        }
        return newID
    }

    /// 在本页底部加一整块触控板 (占满宽 × 4 行)。编辑器「加触控板」用。
    @discardableResult
    func addTrackpad(layerID: String, in target: LayoutTarget? = nil) -> UUID? {
        var newID: UUID?
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            guard !layers[li].keys.contains(where: { $0.kind == .trackpad }) else { return }  // 一页只放一个触控板
            let cols = max(1, layers[li].columns)
            let r = layers[li].rowCount   // 放在现有内容下方, 不和别的键冲突
            let cap = KeyCap(label: "触控板", col: 0, row: r, colSpan: cols, rowSpan: 5, kind: .trackpad)
            guard LayoutBounds.keyFits(cap, columns: layers[li].columns) else { return }
            newID = cap.id
            layers[li].keys.append(cap)
        }
        return newID
    }

    /// 加一个独立鼠标键 (左键/右键)。放在第一个能容下的空位 (4 宽), 放不下就摆到底部。
    @discardableResult
    func addMouseButton(layerID: String, code: String, in target: LayoutTarget? = nil) -> UUID? {
        var newID: UUID?
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            let right = code.lowercased() == "right"
            let span = min(4, max(1, layers[li].columns))
            let pos = LayoutStore.firstFreeRegion(in: layers[li], colSpan: span, rowSpan: 1)
                ?? (col: 0, row: layers[li].rowCount)
            let cap = KeyCap(label: right ? "右键" : "左键", code: right ? "right" : "left",
                             col: pos.col, row: pos.row, colSpan: span, kind: .mouseButton)
            guard LayoutBounds.keyFits(cap, columns: layers[li].columns) else { return }
            newID = cap.id
            layers[li].keys.append(cap)
        }
        return newID
    }

    /// 复制一个键 (内容相同, 全新 id): 优先放在能容下原尺寸的空区域, 放不下就缩成 1×1。
    @discardableResult
    func duplicateKey(layerID: String, capID: UUID, in target: LayoutTarget? = nil) -> UUID? {
        var newID: UUID?
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }),
                  let src = layers[li].keys.first(where: { $0.id == capID }) else { return }
            var copy = src
            copy.id = UUID()
            if let pos = LayoutStore.firstFreeRegion(in: layers[li], colSpan: src.colSpan, rowSpan: src.rowSpan) {
                copy.col = pos.col; copy.row = pos.row
            } else if let pos = LayoutStore.firstFreeCell(in: layers[li]) {
                copy.col = pos.col; copy.row = pos.row; copy.colSpan = 1; copy.rowSpan = 1
            } else { return }
            guard LayoutBounds.keyFits(copy, columns: layers[li].columns) else { return }
            newID = copy.id
            layers[li].keys.append(copy)
        }
        return newID
    }

    func deleteKey(layerID: String, capID: UUID, in target: LayoutTarget? = nil) {
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            layers[li].keys.removeAll { $0.id == capID }
        }
    }

    /// 把键移到 (col,row); 目标区域被占或越界则不动, 返回是否成功。
    @discardableResult
    func moveKey(layerID: String, capID: UUID, toCol col: Int, toRow row: Int, in target: LayoutTarget? = nil) -> Bool {
        var ok = false
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }),
                  let ki = layers[li].keys.firstIndex(where: { $0.id == capID }) else { return }
            let k = layers[li].keys[ki]
            guard LayoutStore.regionFree(in: layers[li], col: col, row: row,
                                         colSpan: k.colSpan, rowSpan: k.rowSpan, excluding: capID) else { return }
            layers[li].keys[ki].col = col
            layers[li].keys[ki].row = row
            ok = true
        }
        return ok
    }

    /// 改键的跨度 (加宽/加高); 撑到被占格或越界则不动, 返回是否成功。
    @discardableResult
    func resizeKey(layerID: String, capID: UUID, colSpan: Int, rowSpan: Int, in target: LayoutTarget? = nil) -> Bool {
        var ok = false
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }),
                  let ki = layers[li].keys.firstIndex(where: { $0.id == capID }) else { return }
            let k = layers[li].keys[ki]
            let cs = max(1, colSpan), rs = max(1, rowSpan)
            guard LayoutStore.regionFree(in: layers[li], col: k.col, row: k.row,
                                         colSpan: cs, rowSpan: rs, excluding: capID) else { return }
            layers[li].keys[ki].colSpan = cs
            layers[li].keys[ki].rowSpan = rs
            ok = true
        }
        return ok
    }

    /// 某键挪到/撑到指定矩形是否放得下 (供编辑器实时预览, 不改数据)。
    func canPlace(layerID: String, capID: UUID, col: Int, row: Int, colSpan: Int, rowSpan: Int, in target: LayoutTarget? = nil) -> Bool {
        guard let l = layer(layerID, in: target) else { return false }
        return LayoutStore.regionFree(in: l, col: col, row: row, colSpan: colSpan, rowSpan: rowSpan, excluding: capID)
    }

    // MARK: - 层 / 列 (当前模式)
    func addLayer(named rawName: String, in target: LayoutTarget? = nil) {
        let name = sanitized(rawName, fallback: "layer\(layers(in: target).count + 1)")
        mutateLayers(target) { layers in
            guard !layers.contains(where: { $0.id == name }) else { return }
            layers.append(KeyLayer(id: name, columns: DefaultLayout.columns, keys: []))   // 空页(靠滑动切换, 不放切层键)
        }
    }

    /// 加一个空白「页」(自动唯一 id), 返回它的 id。设置里点「+」加页用。
    @discardableResult
    func addPage(in target: LayoutTarget? = nil) -> String? {
        var newID: String?
        mutateLayers(target) { layers in
            var id = ""
            repeat { id = "page_\(UUID().uuidString.prefix(6).lowercased())" } while layers.contains { $0.id == id }
            layers.append(KeyLayer(id: id, columns: 12, keys: []))
            newID = id
        }
        return newID
    }

    /// 把某页在顺序里左右移动 (delta -1=左移 / +1=右移)。页 id 不变, 只换数组顺序。
    @discardableResult
    func movePage(id: String, by delta: Int, in target: LayoutTarget? = nil) -> Bool {
        var ok = false
        mutateLayers(target) { layers in
            guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
            let j = i + delta
            guard j >= 0, j < layers.count else { return }
            layers.swapAt(i, j)
            ok = true
        }
        return ok
    }

    func deleteLayer(id: String, in target: LayoutTarget? = nil) {
        mutateLayers(target) { layers in
            guard id != "base", layers.count > 1 else { return }
            layers.removeAll { $0.id == id }
            LayoutStore.unsetJumps(to: id, in: &layers)        // §6.3: 指向被删页的跳转键保留, 变成「未设置目标」
        }
    }

    /// 清空某层的所有按键 (层本身保留)。新建模式后想从零搭布局用。
    func clearLayer(id: String, in target: LayoutTarget? = nil) {
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == id }) else { return }
            layers[li].keys = []
        }
    }

    /// 设置某层列数 (1 ... LayoutBounds.maxColumns, 与读取校验同一个上限)。
    /// 超出范围的请求直接拒绝、保留原值 (不悄悄夹到别的值); 缩小时若有键会越界也拒绝 (避免键跑出网格)。
    func setColumns(layerID: String, _ n: Int, in target: LayoutTarget? = nil) {
        // 先判断再改: 拒绝时不进 mutateLayers (不保存、不把大屏键位标成「编辑过」)
        guard (1...LayoutBounds.maxColumns).contains(n), let l = layer(layerID, in: target), l.columns != n else { return }
        if n < l.columns, l.keys.contains(where: { LayoutBounds.end($0.col, $0.colSpan) > n }) { return }   // 旧数据坐标可能极大: 防溢出
        mutateLayers(target) { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            layers[li].columns = n
        }
    }

    /// 编辑器「网格列数 +1」最多加到的列数 (1.0 的行为; 手机上再多键就挤得没法用)。
    /// 只管这个按钮: store 的读写校验上限仍是 LayoutBounds.maxColumns (256)。大屏编辑器的上限 M3 按 §3.5「每格 ≥ 20 pt」再定, 先沿用这个值。
    static let editorMaxColumns = 16

    /// 「+1」可不可以点: 已到 16 列或已超过 (例如从大屏键位带来的 20 列) 都不可以, 布局保持不动。
    func canAddColumn(layerID: String, in target: LayoutTarget? = nil) -> Bool {
        guard let l = layer(layerID, in: target) else { return false }
        return l.columns < LayoutStore.editorMaxColumns
    }

    func addColumn(layerID: String, in target: LayoutTarget? = nil) {
        guard canAddColumn(layerID: layerID, in: target), let l = layer(layerID, in: target) else { return }
        setColumns(layerID: layerID, l.columns + 1, in: target)
    }
    func removeColumn(layerID: String, in target: LayoutTarget? = nil) { setColumns(layerID: layerID, (layer(layerID, in: target)?.columns ?? DefaultLayout.columns) - 1, in: target) }

    /// 把「当前模式」重置回默认层 (base + more)。
    func resetToDefault() {
        mutateLayers(nil) { layers in layers = DefaultLayout.makeDefault() }
    }

    /// 把「当前模式」的原键位恢复到它的初始基线 (只动原键位; 两套一起重置见 `resetMode(_:scope:)`)。
    func resetCurrentModeLayout() { resetOriginalLayout(computer: currentComputerID, mode: currentModeID) }

    /// 把一个模式的原键位恢复到它的初始基线: 先按名精确匹配内置模式 → 恢复其布局;
    /// 否则按**名称前缀**匹配 (如「Vibe Coding 副本」→ Vibe Coding) → 副本也能重置回原版;
    /// 都不匹配的纯自建模式 → 通用默认。
    func resetOriginalLayout(computer: UUID, mode: UUID) {
        let name = self.mode(computer: computer, mode: mode)?.name ?? ""
        let builtin = BuiltinModes.makeAll().first { $0.name == name }
            ?? BuiltinModes.makeAll().first { !$0.name.isEmpty && name.hasPrefix($0.name) }
        mutateLayers(LayoutTarget(computer: computer, mode: mode, set: .original)) { layers in
            layers = builtin?.layers ?? DefaultLayout.makeDefault()
        }
    }

    /// 删页后的引用处理 (§6.3): 同一套键位里 `targetLayer` 指向已不存在的页的跳转键保留, 目标清空 (显示为「未设置目标」)。
    static func unsetJumps(to removedID: String, in layers: inout [KeyLayer]) {
        for li in layers.indices {
            for ki in layers[li].keys.indices where layers[li].keys[ki].kind == .layer && layers[li].keys[ki].targetLayer == removedID {
                layers[li].keys[ki].targetLayer = nil
            }
        }
    }

    /// 非破坏地补齐内置模式: 每台电脑「按名」缺哪个内置模式就补哪个, 绝不动用户已有模式/编辑。
    /// 内置布局更新**不会**覆盖用户同名模式 —— 优先保住用户数据 (审计【阻断】#1)。
    func addMissingBuiltins() {
        for i in computers.indices {
            let names = Set(computers[i].modes.map(\.name))
            let hasLaptop = computers[i].modes.contains { $0.kind == .laptopKeyboard }
            // 笔记本键盘按类型标识判断 (§4.9: 不能靠名字认; 用户可以自建同名的网格模式), 其余内置沿用按名字补齐
            for b in BuiltinModes.makeAll() where b.kind == .laptopKeyboard ? !hasLaptop : !names.contains(b.name) {
                computers[i].modes.append(b)   // makeAll() 每次生成全新 id, 不撞车
            }
            if computers[i].lastModeID == nil { computers[i].lastModeID = computers[i].modes.first?.id }
        }
        persist()
    }

    /// v10: 按产品决策**强制统一**内置模式阵容 —— 不论新老用户、不论是否编辑过:
    ///   1) 「Vibe Coding」只保留第一页 (丢弃第二页及之后; 保留用户对第一页的编辑);
    ///   2) 删除「鼠标模式」;
    ///   (3) 新的「vibecoding键盘模式」由随后的 addMissingBuiltins 补齐。)
    /// ⚠️ 这是**有意的破坏性**迁移: 会覆盖被编辑过的 Vibe 第二页、删除被编辑过的鼠标模式。
    /// 仅按内置名精确匹配 → 用户**改过名**的模式(已属自建)不受影响; 自建模式一律保留。
    private func applyV10ModeOverhaul(from oldVersion: Int) {
        guard oldVersion < 10 else { return }
        for ci in computers.indices {
            // 1) Vibe Coding 只保留第一页
            if let mi = computers[ci].modes.firstIndex(where: { $0.name == "Vibe Coding" }),
               let first = computers[ci].modes[mi].layers.first {
                computers[ci].modes[mi].layers = [first]
            }
            // 2) 删除「鼠标模式」
            computers[ci].modes.removeAll { $0.name == "鼠标模式" }
            // 兜底: 万一删空了, 至少留一个 Vibe (单页), 避免 0 模式
            if computers[ci].modes.isEmpty { computers[ci].modes = [BuiltinModes.vibe()] }
            // 修复「上次模式」指向被删模式的情况
            if let last = computers[ci].lastModeID,
               !computers[ci].modes.contains(where: { $0.id == last }) {
                computers[ci].lastModeID = computers[ci].modes.first?.id
            }
        }
        // 修复当前选中模式指向被删的鼠标模式的情况
        if let cc = computers.first(where: { $0.id == currentComputerID }),
           !cc.modes.contains(where: { $0.id == currentModeID }) {
            currentModeID = cc.modes.first?.id ?? currentModeID
        }
    }

    /// 内置布局升级只覆盖「仍完全等于旧出厂布局」的模式。
    /// 这样旧用户能得到新版三列柔光键盘，而任何自行编辑过的模式仍原样保留。
    private func upgradeBuiltinLayoutsIfSafe(from version: Int) {
        guard version < BuiltinModes.version else { return }
        for ci in computers.indices {
            // Vibe Coding: 仅当仍完全等于某个历史出厂布局 (v2/v3, 或 v4 同标签布局) 才升级到最新。
            // (v10 起 applyV10ModeOverhaul 会再统一把所有 Vibe 收成单页; 这里只是顺带把旧版未编辑 Vibe 升级到最新出厂。)
            if let mi = computers[ci].modes.firstIndex(where: { $0.name == "Vibe Coding" }),
               isV2VibeLayout(computers[ci].modes[mi]) || isV3VibeLayout(computers[ci].modes[mi])
                || isCurrentFactoryVibe(computers[ci].modes[mi]) {
                computers[ci].modes[mi].layers = BuiltinModes.vibe().layers
            }
            // 工作模式 → 鼠标模式: 未编辑的出厂工作模式(任意历史版本)自动改名 + 换成最新鼠标模式布局。
            // 编辑过的保留原样(仍叫「工作模式」), 之后 addMissingBuiltins 会另外补一个全新「鼠标模式」。
            if let mi = computers[ci].modes.firstIndex(where: { $0.name == "工作模式" }),
               isFactoryWork(computers[ci].modes[mi]) {
                computers[ci].modes[mi].name = "鼠标模式"
                computers[ci].modes[mi].layers = BuiltinModes.mouse().layers
            }
            // v7 鼠标模式(单块触控板, 未编辑) → v8 (触控板 + 独立左键/右键)。
            if let mi = computers[ci].modes.firstIndex(where: { $0.name == "鼠标模式" }),
               isFactoryMouseV7(computers[ci].modes[mi]) {
                computers[ci].modes[mi].layers = BuiltinModes.mouse().layers
            }
        }
    }

    private func isV2VibeLayout(_ mode: Mode) -> Bool {
        let base = mode.layers.first(where: { $0.id == "base" })?.keys ?? []
        return mode.layers.map(\.id) == ["base", "more"]
            && base.map(\.label) == ["Delete", "Space", "Up", "Down", "Typeless", "No", "Yes"]
    }

    /// 当前已发布 (v3) 出厂的 Vibe 布局指纹: 柔光珊瑚三列 (复制/粘贴/撤销…) + 导航页。
    /// 与之完全相同 = 用户没编辑过 → 可安全升级到新版 3×3 / 4×4 编码控制面。
    private func isV3VibeLayout(_ mode: Mode) -> Bool {
        let base = mode.layers.first(where: { $0.id == "base" })?.keys ?? []
        let more = mode.layers.first(where: { $0.id == "more" })?.keys ?? []
        return mode.layers.map(\.id) == ["base", "more"]
            && base.map(\.label) == ["复制", "粘贴", "撤销", "重做", "命令面板", "侧栏", "注释", "运行", "语音输入", "左", "下", "右"]
            && more.map(\.label) == ["上", "左", "下", "右", "Home", "End", "PgUp", "PgDn", "Esc", "主键盘"]
    }

    /// 当前出厂 Vibe 布局的标签指纹 (v4/v5 标签相同, v5 仅把 Effort 键换成 .effort 种类)。
    /// 与之相同 = 用户没改过标签 → 可安全重应用最新出厂布局 (让 Effort 键升级为 .effort)。
    private func isCurrentFactoryVibe(_ mode: Mode) -> Bool {
        let base = mode.layers.first(where: { $0.id == "base" })?.keys ?? []
        let more = mode.layers.first(where: { $0.id == "more" })?.keys ?? []
        return mode.layers.map(\.id) == ["base", "more"]
            && base.map(\.label) == ["向上", "Effort", "权限模式", "向下", "Space", "Backspace", "Esc", "Typeless", "Enter"]
            && more.map(\.label) == ["1", "A", "/plan", "/btw", "2", "B", "/model", "/compact", "3", "C", "↑", "Backspace", "4", "D", "↓", "Enter"]
    }

    private func isV2WorkLayout(_ mode: Mode) -> Bool {
        let base = mode.layers.first(where: { $0.id == "base" })?.keys ?? []
        return mode.layers.map(\.id) == ["base"]
            && base.map(\.label) == ["Copy", "Paste", "Undo", "", "", "", "", "Esc", "Enter", "Delete", "Space", "Typeless"]
    }

    /// 未编辑的出厂「工作模式」: base 层与历史办公布局结构相同(忽略 id, 比 code/mods/位置/种类等),
    /// 或更早的 v2 英文布局。任何对 base 的实质编辑都算「编辑过」→ 不会被改名覆盖。
    /// (不管有没有 v6 的触控板第二页 —— 只看 base 是否仍是出厂办公布局。)
    private func isFactoryWork(_ mode: Mode) -> Bool {
        guard let base = mode.layers.first(where: { $0.id == "base" }) else { return false }
        return layerStructurallyEqual(base, BuiltinModes.legacyWorkBase()) || isV2WorkLayout(mode)
    }

    /// v7 出厂鼠标模式: 单页, 只有一块触控板(没编辑过)。用于升级到 v8 的「触控板 + 左键/右键」。
    private func isFactoryMouseV7(_ mode: Mode) -> Bool {
        guard mode.layers.map(\.id) == ["base"], let base = mode.layers.first else { return false }
        return base.keys.count == 1 && base.keys[0].kind == .trackpad
    }

    /// 两层是否「结构相同」: 列数一致 + 每个键的所有字段(除 UUID)一致。供出厂指纹比对用。
    private func layerStructurallyEqual(_ a: KeyLayer, _ b: KeyLayer) -> Bool {
        guard a.columns == b.columns, a.keys.count == b.keys.count else { return false }
        for (x, y) in zip(a.keys, b.keys) {
            if x.label != y.label || x.code != y.code || x.mods != y.mods
                || x.col != y.col || x.row != y.row || x.colSpan != y.colSpan || x.rowSpan != y.rowSpan
                || x.kind != y.kind || x.targetLayer != y.targetLayer || x.tint != y.tint
                || x.sendText != y.sendText || x.icon != y.icon { return false }
        }
        return true
    }

    /// ⚠️ 破坏性: 整批覆盖每台电脑的所有模式为内置 (Vibe + 工作), 用户自定义模式/编辑会全丢。
    /// 仅供「恢复内置(需显式确认)」与调试 `--reseed` 用; 启动升级走非破坏的 addMissingBuiltins。
    func reseedBuiltins() {
        for i in computers.indices {
            computers[i].modes = BuiltinModes.makeAll()
            computers[i].lastModeID = computers[i].modes.first?.id
        }
        if let ci = computers.firstIndex(where: { $0.id == currentComputerID }) {
            currentModeID = computers[ci].modes.first?.id ?? currentModeID
        }
        persist()
    }

    // MARK: - 持久化
    struct Persisted: Codable {
        var computers: [Computer]
        var currentComputerID: UUID
        var currentModeID: UUID
        var builtinVersion: Int?      // 老存档无此字段→nil(当 0); 落后则启动时自动重种内置布局
    }

    /// 只读: 取已存档里的电脑 id (给「按电脑」状态的首次迁移用); 读不出来返回空。
    static func peekComputerIDs(_ defaults: UserDefaults) -> [UUID] {
        guard let data = defaults.data(forKey: storeKey), let p = try? SidekeyJSON.decode(Persisted.self, from: data),
              isStructurallyValid(p) else { return [] }
        return p.computers.map(\.id)
    }

    #if DEBUG
    /// DEBUG 夹具用: 整体替换某个模式的页并保存。
    func setLayersForDebug(mode: UUID, layers: [KeyLayer]) {
        guard let ci = computers.firstIndex(where: { $0.modes.contains { $0.id == mode } }),
              let mi = computers[ci].modes.firstIndex(where: { $0.id == mode }) else { return }
        computers[ci].modes[mi].layers = layers
        persist()
    }
    #endif

    /// 测试用: 把一个键直接放进某个模式的第一页并保存 (构造含未知键的存档)。
    func setModeKindForTesting(_ mode: UUID, _ kind: ModeKind) {
        guard let ci = computers.firstIndex(where: { $0.modes.contains { $0.id == mode } }),
              let mi = computers[ci].modes.firstIndex(where: { $0.id == mode }) else { return }
        computers[ci].modes[mi].kind = kind
        persist()
    }
    func addKeyForTesting(_ cap: KeyCap, mode: UUID) {
        guard let ci = computers.firstIndex(where: { $0.modes.contains { $0.id == mode } }),
              let mi = computers[ci].modes.firstIndex(where: { $0.id == mode }),
              !computers[ci].modes[mi].layers.isEmpty else { return }
        computers[ci].modes[mi].layers[0].keys.append(cap)
        persist()
    }

    /// 用户选择「使用全新数据继续」: 原始数据已在备份 key 里, 解除写保护, 之后正常存档。
    func resolveRecoveryWithFreshData() {
        guard recovery != nil else { return }
        pendingCredentialIDs = []          // 恢复前的清理记录不再有依据 (原来的电脑可能还在备份里): 只丢记录, 不删凭证
        saveCredentialCleanup()
        persistBlocked = false
        recovery = nil
        persist()
    }

    /// 最近一次成功写入主存档的状态 (启动时为从磁盘读到的状态): 「放弃修改」从它恢复。
    private var committed: (computers: [Computer], currentComputerID: UUID, currentModeID: UUID, unreadable: Set<UUID>)?
    /// 待清理的电脑凭证 id (持久化在 `credentialCleanupKey`)。
    private var pendingCredentialIDs: Set<UUID> = []
    /// 加载时 Keychain **读取失败** (不是「不存在」) 的电脑: 令牌暂时未知, 不能当成「用户清空」去删它的凭证。
    private var tokenUnreadable: Set<UUID> = [] { didSet { unreadableTokenCount = tokenUnreadable.count } }
    /// 已提交的稳定凭证引用: 电脑 id → 修订号 (Keychain 账户 `<id>@<rev>`)。只有换令牌时才生成新的、不再改动的凭证项;
    /// 改名、改键位、令牌未知期间的保留, 都沿用原来的引用 (主存档怎么变都不需要重写令牌)。
    private var tokenRefs: [UUID: String] = [:]
    /// 待回收旧修订的电脑 (持久化在 `revCleanupKey`)。
    private var pendingRevCleanup: Set<UUID> = []
    /// 用户在本次未提交的修改里**明确清空**了令牌的电脑 (区别于「令牌未知」: 读不出来 ≠ 用户清空; 三种意图: 保留未知 / 设置新令牌 / 清空)。
    private var userClearedTokens: Set<UUID> = []
    /// 令牌暂时读不出来的电脑数 (设备锁定等): 大于 0 时这些电脑不按「没有令牌」去连接, 界面提示; 之后会自动重试读取。
    @Published private(set) var unreadableTokenCount = 0
    /// 令牌未知 = Keychain 读不出来且内存里还没有令牌 (草稿里已经填了新令牌就不算未知)。
    func isTokenUnknown(_ id: UUID) -> Bool { tokenUnreadable.contains(id) && (computers.first { $0.id == id }?.token.isEmpty ?? true) }

    /// 重新读取「令牌暂时未知」的电脑的凭证: 读到就填回 (内存和放弃修改的恢复点都更新), 确认不存在就当没有令牌; 仍然读不出来的保持未知。
    func retryUnreadableTokens() {
        for id in tokenUnreadable {
            guard !userClearedTokens.contains(id) else { continue }
            switch LayoutStore.readToken(id, rev: tokenRefs[id]) {
            case .found(let t):
                if let i = computers.firstIndex(where: { $0.id == id }), computers[i].token.isEmpty, !t.isEmpty { computers[i].token = t }
                if var c = committed, let i = c.computers.firstIndex(where: { $0.id == id }), c.computers[i].token.isEmpty { c.computers[i].token = t; committed = c }
                tokenUnreadable.remove(id)
            case .notFound: tokenUnreadable.remove(id)
            case .failed: break
            }
        }
    }

    /// 写主存档。返回这一次是否已写进存档 (调用方一般不看: 修改接口的返回值表示「修改已经生效」, 存档状态见 `hasUnsavedChanges`)。
    /// 顺序: 先把**所有可能落盘的形态**都编码并按读取同一套检查校验
    /// (令牌全抹掉的形态 + 令牌全留明文的形态: 后者是 Keychain 写失败时的最大情形, 其余情形介于两者之间) →
    /// 通过后才动 Keychain → 写主存档 → 按最终数据清理待删凭证 (`runCredentialCleanup`)。
    /// 校验不过 (保存失败): 不碰 Keychain、不写主存档, **内存里的修改保留**并置 `hasUnsavedChanges`; 之后每次修改都重新保存整份数据, 成功即清除。
    /// 范围: 保证的是保存失败时「主存档 / Keychain 不被改动」; 不涉及 Keychain 之外的独立状态 (按电脑偏好等)。
    @discardableResult
    func persist() -> Bool {
        guard !persistBlocked else { return false }
        retryUnreadableTokens()
        func encode(_ list: [Computer]) -> Data? {
            let p = Persisted(computers: list, currentComputerID: currentComputerID,
                              currentModeID: currentModeID, builtinVersion: BuiltinModes.version)
            guard let data = try? SidekeyJSON.encode(p), (try? JSONParser.parse(data)) != nil else { return nil }
            return data
        }
        // 令牌存 Keychain, 不写进明文 JSON。Keychain 写失败(极少见)的那台保留明文兜底, 绝不丢令牌(否则用户要重新配对)。
        // 取令牌的策略: 以最后一次成功保存的主存档为准 —— 主存档里有明文就用明文 (1.0 遗留的明文、Keychain 写失败的兜底、Keychain 已更新但主存档还没提交时崩溃),
        // 为空才取 Keychain; 持续写不进 Keychain 时明文会一直留着, 这是兜底策略本身的限制。
        // 令牌按**稳定引用**存 Keychain: 令牌没变就沿用原引用; 换了令牌 (或新电脑) 才写一个新的、不再改动的 `<id>@<rev>` 项;
        // 令牌未知 (读不出来) 且用户没动它 → 沿用原引用。Keychain 写失败的那台改用明文兜底 (已预检过最大形态), 不再循环重写。
        // 这次新写的项记在 `written`, 提交前任何失败出口都把它们删掉 (保存失败时 Keychain 一点不变)。
        // 先在动 Keychain 之前把所有可能落盘的形态都校验完: 令牌全抹掉的形态 + 令牌全留明文的最大形态 (Keychain 全部写失败时), 其余介于两者之间。
        var strippedAll = computers
        for i in strippedAll.indices { strippedAll[i].token = "" }
        guard encode(strippedAll) != nil, let mainMax = encode(computers) else { return markUnsaved() }
        // 大屏键位 (独立 key, §6.4 第 5 条): 会落到磁盘的每一个形态都先编码校验 —— 中间形态「新记录 ∪ 这次被移除的旧记录」(带提交依据) 和最终形态;
        // 并且任何时刻磁盘上「主存档 + 大屏存档」的合计都不超过同一个上限。有一个放不下就整次保存失败 (保留草稿, Keychain / 凭证记录 / 存档都不动), 不跳过任何一步写入。
        // 大屏键位处于恢复状态时不写它 (写保护), 但它磁盘上的原始数据仍计入合计。
        let liveLarge = largeEntriesForSave()
        let removedLarge = committedLarge.filter { liveLarge[$0.key] == nil }
        let writesLarge = !largeBlocked && !(liveLarge.isEmpty && defaults.object(forKey: LayoutStore.largeStoreKey) == nil)   // 从来没生成过且现在也没有: 不建这个 key
        var largeData: Data?
        if writesLarge {
            let oldMain = defaults.data(forKey: LayoutStore.storeKey)?.count ?? 0
            guard let final = LayoutStore.encodeLarge(liveLarge),
                  let superset = LayoutStore.encodeLarge(removedLarge.merging(liveLarge) { _, new in new },
                                                         pending: LargePending(main: String(repeating: "0", count: 64), drop: removedLarge.keys.map(\.raw).sorted())),
                  oldMain + superset.count <= JSONParser.maxBytes,           // 写中间形态之后、写主存档之前
                  mainMax.count + superset.count <= JSONParser.maxBytes,     // 写主存档之后、收敛之前
                  mainMax.count + final.count <= JSONParser.maxBytes         // 收敛之后
            else { return markUnsaved() }
            largeData = final
        } else {
            guard mainMax.count + largeDiskSize() <= JSONParser.maxBytes else { return markUnsaved() }
        }
        let committedTokens = Dictionary((committed?.computers ?? []).map { ($0.id, $0.token) }, uniquingKeysWith: { a, _ in a })
        var newRefs: [UUID: String] = [:]
        var written: [String] = []
        var fallback = Set<Int>()
        for (i, c) in computers.enumerated() {
            if c.token.isEmpty {
                if tokenUnreadable.contains(c.id), !userClearedTokens.contains(c.id), let r = tokenRefs[c.id] { newRefs[c.id] = r }
                continue
            }
            if let r = tokenRefs[c.id], committedTokens[c.id] == c.token { newRefs[c.id] = r; continue }
            let rev = String(UUID().uuidString.prefix(8)).lowercased()
            let acct = LayoutStore.tokenAccount(c.id, rev: rev)
            if KeychainToken.set(c.token, for: acct) { newRefs[c.id] = rev; written.append(acct) } else { fallback.insert(i) }
        }
        func rollbackWritten() -> Bool { for a in written { KeychainToken.delete(a) }; return markUnsaved() }
        var list = computers
        for i in list.indices where !fallback.contains(i) { list[i].token = "" }
        guard let data = encode(list) else { return rollbackWritten() }      // 不会发生: 最大形态已校验过
        // 令牌为空且不是「Keychain 暂时读不出来」的电脑 = 用户明确清空 (或本来就没有): 记墓碑, 随主存档一起提交,
        // 加载时忽略 Keychain 里可能残留的旧项 (删除失败也不会复活); 提交后再尽力删旧项。
        let clearedNow = Set(computers.filter { $0.token.isEmpty && (!tokenUnreadable.contains($0.id) || userClearedTokens.contains($0.id)) }.map(\.id))
        // 凭证记录与主存档配对 (按完整字节哈希): 先写「新主存档配新记录」+ 保留「旧主存档配旧记录」两条, 再写主存档, 最后收敛成只剩新的一条。
        // 崩溃发生在任意两次写入之间, 加载时主存档是旧的就匹配旧记录 (旧引用的旧令牌项还在)、是新的就匹配新记录, 不会错配。
        let newEntry = LayoutStore.CredEntry(hash: LayoutStore.blobHash(data), cleared: clearedNow.map(\.uuidString).sorted(),
                                            refs: Dictionary(uniqueKeysWithValues: newRefs.map { ($0.key.uuidString, $0.value) }))
        var entries = [newEntry]
        if let prev = defaults.data(forKey: LayoutStore.storeKey),
           let old = LayoutStore.credEntries(in: defaults).first(where: { $0.hash == LayoutStore.blobHash(prev) }), old.hash != newEntry.hash { entries.append(old) }
        // 大屏键位与主存档的写入顺序: 先写「新记录 ∪ 这次被移除的旧记录」并附上提交依据 (新主存档的完整哈希 + 要移除的索引) → 主存档 → 只剩新记录。
        // 崩溃在中间时: 磁盘上还是旧主存档 → 被移除的旧记录照常有效; 已是新主存档 → 按提交依据移除 (包括「两套都重置」这种模式还在、记录要删的情况)。
        // 用户编辑过的大屏键位不会因为崩溃丢失, 已重置 / 已删除的也不会复活。中间形态的大小已在前面按同样长度的哈希预检过。
        var superset: Data?
        if largeData != nil {
            guard let d = LayoutStore.encodeLarge(removedLarge.merging(liveLarge) { _, new in new },
                                                  pending: LargePending(main: LayoutStore.blobHash(data), drop: removedLarge.keys.map(\.raw).sorted()))
            else { return rollbackWritten() }                                  // 不会发生: 同样内容、同样长度已预检
            superset = d
        }
        LayoutStore.writeCredEntries(entries, in: defaults)
        if let superset { defaults.set(superset, forKey: LayoutStore.largeStoreKey) }
        defaults.set(data, forKey: LayoutStore.storeKey)
        LayoutStore.writeCredEntries([newEntry], in: defaults)
        if let largeData { defaults.set(largeData, forKey: LayoutStore.largeStoreKey) }
        large = liveLarge
        committedLarge = liveLarge
        // 提交后**立刻**把回收队列落盘 (有令牌的 + 清空的电脑): 万一在下面的回收之前被关闭, 下次启动还能把旧修订删掉, 不留无记录的孤儿项。
        pendingRevCleanup.formUnion(computers.filter { !$0.token.isEmpty || clearedNow.contains($0.id) }.map(\.id))
        saveRevCleanup()
        // 提交之后 (尽力): 写镜像 `<id>` (给 1.0 读); 清空的电脑删掉全部项; 其余电脑排队回收旧修订 (删除 / 枚举失败的留着重试)。
        tokenRefs = newRefs
        for (i, c) in computers.enumerated() {
            if clearedNow.contains(c.id) { if !KeychainToken.deleteAll(id: c.id.uuidString) { pendingRevCleanup.insert(c.id) }; continue }
            guard !c.token.isEmpty else { continue }            // 令牌未知的电脑: 不动它的凭证
            if !KeychainToken.set(c.token, for: c.id.uuidString), fallback.contains(i) { KeychainToken.delete(c.id.uuidString) }   // 镜像写不进就删掉, 免得 1.0 读到旧值
            pendingRevCleanup.insert(c.id)
        }
        for c in computers where !c.token.isEmpty { tokenUnreadable.remove(c.id) }
        tokenUnreadable.subtract(clearedNow)                                      // 用户明确清空的: 不再「未知」
        userClearedTokens = []
        committed = (computers, currentComputerID, currentModeID, tokenUnreadable)
        hasUnsavedChanges = false
        defaults.removeObject(forKey: LayoutStore.unsavedMarkerKey)
        runCredentialCleanup()
        runRevCleanup()
        return true
    }

    private func markUnsaved() -> Bool {
        if !hasUnsavedChanges { DebugTimeline.record("persist failed: unsaved changes kept in memory") }
        hasUnsavedChanges = true
        defaults.set(true, forKey: LayoutStore.unsavedMarkerKey)       // 单独的小标记: 万一 App 被关闭, 下次启动提示一次
        return false
    }

    private func saveCredentialCleanup() {
        if pendingCredentialIDs.isEmpty { defaults.removeObject(forKey: LayoutStore.credentialCleanupKey) }
        else { defaults.set(pendingCredentialIDs.map(\.uuidString).sorted(), forKey: LayoutStore.credentialCleanupKey) }
    }

    /// 按**最终已提交的数据**算出该清理哪些凭证 (不重放历史的删除动作): 存档里已经有这台电脑 (同 id 加回来 / 放弃修改) 就取消它的清理;
    /// 没有才删。"current" 缓存只在它确实属于这台电脑 (令牌相同, 且没有别的电脑在用同一个令牌) 时才清。
    /// 顺序: 先清 current (失败就保留记录、不动这台的凭证, 下次还能比对), 再删这台的凭证。
    /// 恢复状态 (v5 读不出来) 下不清理: 这时内存里是恢复用的默认数据, 证明不了原来的电脑已经被删。
    /// 这是「尽力回收孤儿凭证」, 不是跨存储的原子事务; 但**不能**拿它豁免误删有效凭证。
    private func runCredentialCleanup() {
        guard !persistBlocked, recovery == nil, !pendingCredentialIDs.isEmpty else { return }
        let alive = committed?.computers ?? computers
        let aliveIDs = Set(alive.map(\.id))
        for id in pendingCredentialIDs {
            if aliveIDs.contains(id) { pendingCredentialIDs.remove(id); continue }
            if case .found(let token) = KeychainToken.read(id.uuidString), !token.isEmpty,
               KeychainToken.get("current") == token, !alive.contains(where: { $0.token == token }) {
                guard KeychainToken.delete("current") else { continue }
            }
            guard KeychainToken.deleteAll(id: id.uuidString) else { continue }
            pendingCredentialIDs.remove(id)
        }
        saveCredentialCleanup()
    }

    /// 回收旧修订: 对排队的电脑, 删掉除当前引用之外的 `<id>@<rev>` 项 (当前没有引用就全删; 电脑已不在存档里的交给 `runCredentialCleanup`)。
    /// 枚举或删除失败就保留任务 (持久化), 下次保存成功 / 启动时重试。恢复状态下不做。
    private func runRevCleanup() {
        guard !persistBlocked, recovery == nil, !pendingRevCleanup.isEmpty else { return }
        let alive = Set((committed?.computers ?? computers).map(\.id))
        for id in pendingRevCleanup {
            guard alive.contains(id) else { pendingRevCleanup.remove(id); continue }
            guard let list = KeychainToken.accounts(prefix: id.uuidString + "@") else { continue }      // 枚举失败: 保留任务
            let keep = tokenRefs[id].map { LayoutStore.tokenAccount(id, rev: $0) }
            var ok = true
            for a in list where a != keep { ok = KeychainToken.delete(a) && ok }
            if ok { pendingRevCleanup.remove(id) }
        }
        saveRevCleanup()
    }

    private func saveRevCleanup() {
        if pendingRevCleanup.isEmpty { defaults.removeObject(forKey: LayoutStore.revCleanupKey) }
        else { defaults.set(pendingRevCleanup.map(\.uuidString).sorted(), forKey: LayoutStore.revCleanupKey) }
    }

    /// 「重试保存」/ App 进入后台时调用: 把当前内存里的整份数据再存一次。
    @discardableResult
    func retryUnsavedSave() -> Bool {
        guard hasUnsavedChanges else { return true }
        return persist()
    }

    /// 「放弃修改」: 从最后一次成功保存的数据重新载入 (不动 Keychain、不写主存档)。
    func discardUnsavedChanges() {
        guard hasUnsavedChanges, let c = committed else { return }
        computers = c.computers
        large = committedLarge
        currentComputerID = c.currentComputerID
        currentModeID = c.currentModeID
        tokenUnreadable = c.unreadable                 // 凭证状态也在恢复点里: 草稿里填的新令牌被放弃后, 「未知」状态回来
        userClearedTokens = []
        pendingCredentialIDs.subtract(c.computers.map(\.id))      // 放弃后这些电脑回来了: 取消它们的清理
        saveCredentialCleanup()
        hasUnsavedChanges = false
        defaults.removeObject(forKey: LayoutStore.unsavedMarkerKey)
        discardGeneration += 1
    }

    /// 用户确认「上次有修改没能保存」的提示。
    func acknowledgePreviousSessionLoss() {
        previousSessionLostChanges = false
        defaults.removeObject(forKey: LayoutStore.unsavedNoticeKey)
    }

    /// 读取存档; v5 优先; 没有则从 v4 迁移 (保留电脑/连接, 缺的内置模式由 addMissingBuiltins 非破坏补齐);
    /// 再没有则从 v3 迁移 (保留电脑/模式名, 布局重置); 都没有就种一份全新默认 (种入全部内置模式)。
    /// 第二个返回值非 nil = v5 存档存在但读不出来: 此时不回退到 v4/v3 (会让下次保存覆盖原始数据),
    /// 返回全新默认数据 + 原始数据, 由调用方进入恢复流程。原始数据同时备份到 `corruptBackupKey`。
    private static func load(from defaults: UserDefaults) -> (Persisted, Data?, Set<UUID>, [UUID: String]) {
        // v5 存在时: 解码 + 结构验证, 任何一步不过都进恢复流程; **只有 v5 不存在**才回退 v4 / v3 / 默认。
        if let data = defaults.data(forKey: storeKey) {
            guard let p = try? SidekeyJSON.decode(Persisted.self, from: data), isStructurallyValid(p) else {
                backUpCorrupt(data, in: defaults)
                return (freshDefault(), data, [], [:])
            }
            let refs = tokenRefs(for: data, in: defaults)
            let (restored, unreadable) = restoringTokens(p, cleared: tombstones(for: data, in: defaults), refs: refs)
            return (restored, nil, unreadable, refs)
        }
        return (loadLegacyOrDefault(from: defaults), nil, [], [:])
    }

    // MARK: 令牌按稳定引用存 Keychain
    static func tokenAccount(_ id: UUID, rev: String) -> String { "\(id.uuidString)@\(rev)" }
    /// 按引用读令牌: 有引用就只读 `<id>@<rev>` (不存在 = 没有令牌, 不退回镜像); 没有引用 (旧存档 / 1.0 迁移) 才读镜像 `<id>`。
    static func readToken(_ id: UUID, rev: String?) -> KeychainToken.ReadResult {
        if let rev { return KeychainToken.read(tokenAccount(id, rev: rev)) }
        return KeychainToken.read(id.uuidString)
    }

    /// 编辑电脑时对令牌的三种意图 (不靠「字符串是否为空」推断): 保留 store 里的当前值 / 设置新令牌 / 明确清空。
    enum TokenEdit: Equatable { case keep, set(String), clear }

    // MARK: 凭证记录 (与主存档字节配对: 墓碑 + 稳定引用)
    struct CredEntry { var hash: String; var cleared: [String]; var refs: [String: String] }
    static func blobHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func credEntries(in defaults: UserDefaults) -> [CredEntry] {
        (defaults.array(forKey: clearedTokensKey) as? [[String: Any]] ?? []).compactMap {
            guard let h = $0["h"] as? String else { return nil }
            return CredEntry(hash: h, cleared: $0["ids"] as? [String] ?? [], refs: $0["refs"] as? [String: String] ?? [:])
        }
    }
    private static func entry(for blob: Data, in defaults: UserDefaults) -> CredEntry? {
        let h = blobHash(blob)
        return credEntries(in: defaults).first { $0.hash == h }
    }
    /// 与给定主存档字节配对的墓碑 (没有匹配的记录 = 没有墓碑)。
    static func tombstones(for blob: Data, in defaults: UserDefaults) -> Set<UUID> {
        Set((entry(for: blob, in: defaults)?.cleared ?? []).compactMap(UUID.init(uuidString:)))
    }
    /// 与给定主存档字节配对的凭证引用。
    static func tokenRefs(for blob: Data, in defaults: UserDefaults) -> [UUID: String] {
        var r: [UUID: String] = [:]
        for (k, v) in entry(for: blob, in: defaults)?.refs ?? [:] { if let id = UUID(uuidString: k) { r[id] = v } }
        return r
    }
    private static func writeCredEntries(_ entries: [CredEntry], in defaults: UserDefaults) {
        defaults.set(entries.map { ["h": $0.hash, "ids": $0.cleared, "refs": $0.refs] as [String: Any] }, forKey: clearedTokensKey)
    }

    /// 结构验证: 合法 JSON 也可能是无效结构 (没有电脑、电脑没有任何模式), 这类数据不能当成有效存档继续写回。
    static func isStructurallyValid(_ p: Persisted) -> Bool {
        !p.computers.isEmpty && p.computers.allSatisfy { !$0.modes.isEmpty }
    }

    /// 填回令牌: blob 里有明文就沿用 (旧明文存档 / Keychain 写失败的兜底 → 下次 persist 迁进 Keychain), 没有才取 Keychain。
    /// 每台电脑**只读一次** Keychain, 同时得到值和状态 (读到 / 不存在 / 读取失败): 读取失败的电脑令牌暂时未知, 返回它们的 id。
    private static func restoringTokens(_ p: Persisted, cleared: Set<UUID>, refs: [UUID: String]) -> (Persisted, Set<UUID>) {
        var p = p
        var unreadable = Set<UUID>()
        for i in p.computers.indices {
            // 令牌优先级: 以最后一次成功保存的主存档为准 —— blob 里有明文就用明文 (之后的保存会再次尝试写 Keychain); blob 里是空的才取 Keychain
            // (保存时令牌为空的电脑会连带删掉 Keychain 里的旧项, 所以「空」只会是「已迁入 Keychain」或「确实没有令牌」)。
            guard p.computers[i].token.isEmpty, !cleared.contains(p.computers[i].id) else { continue }
            switch readToken(p.computers[i].id, rev: refs[p.computers[i].id]) {
            case .found(let t): if !t.isEmpty { p.computers[i].token = t }
            case .notFound: break
            case .failed: unreadable.insert(p.computers[i].id)
            }
        }
        return (p, unreadable)
    }

    private static func freshDefault() -> Persisted {
        let computer = Computer.make(name: "我的电脑")
        let modeID = computer.modes.first?.id ?? UUID()
        return Persisted(computers: [computer], currentComputerID: computer.id, currentModeID: modeID,
                         builtinVersion: BuiltinModes.version)
    }

    private static func loadLegacyOrDefault(from defaults: UserDefaults) -> Persisted {
        // v4 → v5: 用户的电脑/模式/布局**原样保留** (v4 已是网格模型, 直接可用);
        // 缺的内置模式由 init 的 addMissingBuiltins() 非破坏补齐 (不删用户模式)。审计【阻断】#1。
        if let data = defaults.data(forKey: legacyV4Key),
           var v4 = try? SidekeyJSON.decode(Persisted.self, from: data),
           isStructurallyValid(v4) {
            v4.builtinVersion = nil      // 触发 addMissingBuiltins 补内置
            return v4
        }
        if let data = defaults.data(forKey: legacyV3Key),
           let v3 = try? JSONDecoder().decode(LegacyV3.self, from: data),
           !v3.computers.isEmpty {
            // v3 是行流式布局, 无法无损映射到 v5 网格, 故布局重置为默认(电脑/模式名保留)。为避免"静默丢布局",
            // 迁移前把原始 v3 blob 备份到独立 key(原 key 也不删), 留一份给将来可能的恢复 (审计: Codex High-2)。
            defaults.set(data, forKey: legacyV3BackupKey)
            let computers = v3.computers.map { c -> Computer in
                let modes = c.modes.map { Mode(id: $0.id, name: $0.name, layers: DefaultLayout.makeDefault()) }
                return Computer(id: c.id, name: c.name, host: c.host, port: c.port, token: c.token,
                                modes: modes.isEmpty ? [Mode.makeDefault(name: "默认")] : modes,
                                lastModeID: c.lastModeID)
            }
            return Persisted(computers: computers,
                             currentComputerID: v3.currentComputerID,
                             currentModeID: v3.currentModeID,
                             builtinVersion: BuiltinModes.version)
        }
        return freshDefault()
    }

    /// 只用于读 v3 老存档: 故意省略 `layers` 字段 (Codable 自动忽略), 迁移时布局一律重置。
    private struct LegacyV3: Codable {
        struct LMode: Codable { var id: UUID; var name: String }
        struct LComputer: Codable {
            var id: UUID; var name: String; var host: String; var port: Int
            var token: String; var modes: [LMode]; var lastModeID: UUID?
        }
        var computers: [LComputer]
        var currentComputerID: UUID
        var currentModeID: UUID
    }

    private func sanitized(_ s: String, fallback: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        return t.isEmpty ? fallback : t
    }
}
