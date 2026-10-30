import Foundation

/// 大屏键位的索引: 电脑 id + 模式 id (§6.4 第 1 条)。存档里写成 "<电脑>/<模式>"。
struct LargeKey: Hashable {
    var computer: UUID
    var mode: UUID
    var raw: String { "\(computer.uuidString)/\(mode.uuidString)" }
    init(computer: UUID, mode: UUID) { self.computer = computer; self.mode = mode }
    init?(raw: String) {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let c = UUID(uuidString: String(parts[0])), let m = UUID(uuidString: String(parts[1])) else { return nil }
        computer = c; mode = m
    }
}

/// 保存中途写下的提交依据 (§6.4): 主存档写成哈希为 `main` 的那份之后, 记录里的 `drop` 这些索引作废。
/// 用来恢复「模式还在、但它的大屏键位记录这次要删」(两套都重置等) 的中断提交; 只靠模式是否存在判断不了。
struct LargePending: Codable, Equatable {
    var main: String          // 新主存档完整字节的 SHA-256 (十六进制)
    var drop: [String]        // 要移除的 "<电脑>/<模式>"
}

/// 大屏键位的读写、生成和重置 (§6)。存在独立 key `sidekey.large.v1`, v5 主存档结构不变, 旧版 App 碰不到。
/// 写入并入 `persist()` (同一次保存先校验主存档和大屏键位, 再按崩溃安全的顺序写), 所以保存失败、放弃修改、恢复流程都和主存档同一套规则。
extension LayoutStore {
    nonisolated static let largeStoreKey = "sidekey.large.v1"
    nonisolated static let largeCorruptPrefix = "sidekey.large.v1.corrupt"
    static let largeFormatVersion = 1

    /// 存档格式: 版本号 + 按 "<电脑>/<模式>" 索引的记录 + (只在保存中途的中间形态里出现的) 提交依据。
    struct LargeFile: Codable {
        var v: Int
        var entries: [String: LargeLayout]
        var pending: LargePending? = nil
    }


    // MARK: - 读取 (启动时)

    /// 读 `sidekey.large.v1`。没有这个 key = 一个都还没生成。
    /// 读不出来 (解析失败、版本不认识、结构不合法) → 原始数据备份到 `sidekey.large.v1.corrupt.N`, 进入大屏键位的恢复状态:
    /// 在用户处理前不写这个 key (§6.4 第 5 条), 主存档照常读写。
    func loadLarge() {
        // 区分「key 不存在」(= 一个都还没生成) 和「key 存在但读不出来」(类型不对也算): 后者备份原值、进入大屏键位的恢复流程, 原值不动
        guard let value = defaults.object(forKey: LayoutStore.largeStoreKey) else { large = [:]; return }
        guard let data = value as? Data, let file = LayoutStore.decodeLargeFile(data) else {
            let raw = LayoutStore.rawBytes(of: value)
            LayoutStore.backUpCorrupt(raw, in: defaults, prefix: LayoutStore.largeCorruptPrefix)
            largeRecovery = Recovery(rawData: raw)
            large = [:]
            return
        }
        var entries = file.entries
        // 中途中断的保存留下的提交依据: 磁盘上的主存档就是那次要提交的 (完整哈希一致) → 按它移除记录 (删除模式 / 两套都重置等);
        // 不一致 (主存档还是旧的) → 这些记录对旧主存档仍有效, 保留
        if let p = file.pending, let main = defaults.data(forKey: LayoutStore.storeKey), LayoutStore.blobHash(main) == p.main {
            for raw in p.drop { if let k = LargeKey(raw: raw) { entries[k] = nil } }
        }
        // 降级期间被删掉的模式 / 电脑 (§6.4 第 6 条): 主存档读出来了才清, 主存档在恢复状态时 (内存里是默认数据) 不能据此判断
        large = recovery == nil ? entries.filter { modeExists($0.key) } : entries
    }

    /// 只解出记录 (不含提交依据), 测试和工具用。
    static func decodeLarge(_ data: Data) -> [LargeKey: LargeLayout]? { decodeLargeFile(data)?.entries }

    /// 解析 + 校验: 版本号、索引合法且归一化后不重复 (UUID 大小写不同的同一个 id 也算重复)、每条记录结构合法。任何一项不过返回 nil。
    static func decodeLargeFile(_ data: Data) -> (entries: [LargeKey: LargeLayout], pending: LargePending?)? {
        guard let file = try? SidekeyJSON.decode(LargeFile.self, from: data), file.v == largeFormatVersion else { return nil }
        var out: [LargeKey: LargeLayout] = [:]
        for (raw, layout) in file.entries {
            guard let key = LargeKey(raw: raw), out[key] == nil, isStructurallyValid(layout) else { return nil }
            out[key] = layout
        }
        if let p = file.pending {
            // 新主存档的 SHA-256: 必须正好是 64 位小写 ASCII 十六进制 (blobHash 的输出格式)
            let hexOK = p.main.utf8.count == 64 && p.main.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            guard hexOK, p.drop.allSatisfy({ LargeKey(raw: $0) != nil }) else { return nil }
        }
        return (out, file.pending)
    }

    /// 存档里任意类型的值转成可备份 / 可导出的字节 (字符串按 UTF-8, 其余按属性列表)。
    static func rawBytes(of value: Any) -> Data {
        if let d = value as? Data { return d }
        if let s = value as? String { return Data(s.utf8) }
        return (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
    }

    /// 磁盘上大屏键位 key 当前占的字节数 (计入「主存档 + 大屏存档」合计上限)。
    func largeDiskSize() -> Int {
        guard let v = defaults.object(forKey: LayoutStore.largeStoreKey) else { return 0 }
        return LayoutStore.rawBytes(of: v).count
    }

    /// 结构检查: 至少一页、页 id 不重复且非空、列数 ≥ 1、每个键坐标 / 跨度合法; 鼠标键正好左、右各一个。
    static func isStructurallyValid(_ l: LargeLayout) -> Bool {
        guard !l.layers.isEmpty, Set(l.layers.map(\.id)).count == l.layers.count else { return false }
        // 几何范围与编辑、生成共用 LayoutBounds (§6.4 第 5 条「读写一致」): 网格里的键必须整个在网格内
        guard l.layers.allSatisfy({ !$0.id.isEmpty && LayoutBounds.layerFits($0) }) else { return false }
        guard l.mouseButtons.allSatisfy(LayoutBounds.valuesInRange) else { return false }     // 鼠标键不在网格里, 只检查数值
        let sides = l.mouseButtons.map(LargeLayoutGenerator.buttonSide)
        return sides == ["left", "right"] && l.mouseButtons.allSatisfy { $0.kind == .mouseButton }
    }

    // MARK: - 保存 (由 persist 调用)

    /// 这次要写的记录: 只留主存档里还存在的 (电脑, 模式)。
    func largeEntriesForSave() -> [LargeKey: LargeLayout] { large.filter { modeExists($0.key) } }

    /// 编码并按读取同一套检查校验 (大小 / 深度上限等); 不过返回 nil (整次保存按失败处理)。
    /// 编码后用**读取时的同一套解析和结构校验**再读一遍 (§6.4 第 5 条: 写出去的存档必须自己读得回来); 读不回来返回 nil (整次保存按失败处理)。
    static func encodeLarge(_ entries: [LargeKey: LargeLayout], pending: LargePending? = nil) -> Data? {
        let file = LargeFile(v: largeFormatVersion, entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.raw, $0.value) }),
                             pending: pending.flatMap { $0.drop.isEmpty ? nil : $0 })
        guard let data = try? SidekeyJSON.encode(file), decodeLargeFile(data) != nil else { return nil }
        return data
    }

    func modeExists(_ k: LargeKey) -> Bool { mode(computer: k.computer, mode: k.mode) != nil }

    // MARK: - 查询

    func largeLayout(computer: UUID, mode: UUID) -> LargeLayout? { large[LargeKey(computer: computer, mode: mode)] }

    /// 内屏上这个模式为什么用不了大屏键位 (nil = 可以用 / 已生成)。编辑器和主界面据此提示。
    enum LargeUnavailable { case recovering, outOfBounds, notGridMode }
    func largeUnavailableReason(computer: UUID, mode: UUID) -> LargeUnavailable? {
        if large[LargeKey(computer: computer, mode: mode)] != nil { return nil }
        if largeBlocked || recovery != nil { return .recovering }
        guard let m = self.mode(computer: computer, mode: mode) else { return nil }
        if !LargeLayoutGenerator.supports(m) { return .notGridMode }
        if !LayoutBounds.layersFit(m.layers) { return .outOfBounds }
        return nil
    }

    // MARK: - 生成 (§6.2)

    /// 第一次在内屏打开一个模式时调用: 已有记录就原样返回 (不论原键位后来怎么改、大屏键位编辑过没有, 都不覆盖);
    /// 没有才按 §6.1 生成并保存。由共享的 store 在主线程一次完成, 两个窗口同时触发也只生成、保存一份。
    /// 不生成的情况: 笔记本键盘等非网格模式、模式不存在、主存档或大屏键位处于恢复状态 (返回 nil)。
    @discardableResult
    func ensureLarge(computer: UUID, mode: UUID) -> LargeLayout? {
        let key = LargeKey(computer: computer, mode: mode)
        if let existing = large[key] { return existing }
        guard recovery == nil, !largeBlocked, let m = self.mode(computer: computer, mode: mode),
              let generated = LargeLayoutGenerator.generate(from: m) else { return nil }
        large[key] = generated
        persist()
        return generated
    }

    /// 「从原键位重新生成」(手动, 界面上先二次确认): 用当前的原键位替换大屏键位, 之前对大屏键位的编辑丢弃。
    @discardableResult
    func regenerateLarge(computer: UUID, mode: UUID) -> Bool {
        guard !largeBlocked, let m = self.mode(computer: computer, mode: mode),
              let generated = LargeLayoutGenerator.generate(from: m) else { return false }
        large[LargeKey(computer: computer, mode: mode)] = generated
        persist()
        return true
    }

    // MARK: - 重置模式 (§6.3)

    enum ResetScope { case currentSet, both }

    /// 重置模式, 范围二选一:
    /// - 只重置当前这套: 原键位 → 恢复初始基线 (大屏键位不动); 大屏键位 → 从当前原键位重新生成 (原键位不动)。
    /// - 两套都重置: 原键位恢复初始基线, 大屏键位恢复为「还没生成」(下次进内屏按重置后的原键位生成)。
    func resetMode(_ target: LayoutTarget, scope: ResetScope) {
        switch (scope, target.set) {
        case (.currentSet, .original):
            resetOriginalLayout(computer: target.computer, mode: target.mode)
        case (.currentSet, .large):
            regenerateLarge(computer: target.computer, mode: target.mode)
        case (.both, _):
            large[LargeKey(computer: target.computer, mode: target.mode)] = nil
            resetOriginalLayout(computer: target.computer, mode: target.mode)      // 内部 persist, 一次写入两边
        }
    }

    // MARK: - 恢复 (大屏键位读不出来)

    /// 用户选择不再保留读不出来的大屏键位: 原始数据仍在备份 key 里; 之后按 §6.2 重新生成。
    func resolveLargeRecoveryWithFreshData() {
        guard largeBlocked else { return }
        largeRecovery = nil
        large = [:]
        committedLarge = [:]
        persist()
    }
}
