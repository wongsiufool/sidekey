import Foundation
import Security

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
    /// ⚠️ 「先删后加」是关键不变量: 写失败时一定不留旧值, 这样 load() 取不到→回退 blob 的较新令牌。
    /// 若日后改成 SecItemUpdate 优化, 失败可能留下陈旧值反而盖过 blob 的新令牌 —— 不要这么改。
    @discardableResult
    static func set(_ token: String, for account: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        SecItemDelete(base(account) as CFDictionary)            // 先删后加, 保证覆盖
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let st = SecItemDelete(base(account) as CFDictionary)
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

    private let defaults: UserDefaults

    private static let storeKey = "sidekey.app.v5"        // v5: 模式集存储 schema (内置模式清单见 BuiltinModes.makeAll())
    private static let legacyV4Key = "sidekey.app.v4"     // v4: 网格布局模型 (迁移: 保留电脑/连接, 模式重种为内置两套)
    private static let legacyV3Key = "sidekey.app.v3"     // v3: 行流式布局 (迁移时只保留电脑/模式, 布局重置)
    private static let legacyV3BackupKey = "sidekey.app.v3.backup"   // 迁移前的 v3 原始存档备份, 布局重置不等于丢原始数据 (审计: Codex High-2)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let p = LayoutStore.load(from: defaults)
        computers = p.computers
        currentComputerID = p.currentComputerID
        currentModeID = p.currentModeID
        // 容错: 修复无效的当前选择。
        if !computers.contains(where: { $0.id == currentComputerID }) {
            currentComputerID = computers[0].id
        }
        let modes = computers.first { $0.id == currentComputerID }?.modes ?? []
        if !modes.contains(where: { $0.id == currentModeID }) {
            currentModeID = modes.first?.id ?? currentModeID
        }
        // 内置布局升级: 旧存档版本落后 → 升级内置模式。
        if (p.builtinVersion ?? 0) < BuiltinModes.version {
            upgradeBuiltinLayoutsIfSafe(from: p.builtinVersion ?? 0)   // 非破坏: 仅升级未编辑的旧出厂布局
            applyV10ModeOverhaul(from: p.builtinVersion ?? 0)          // v10: 强制统一阵容 (有意破坏性)
            addMissingBuiltins()  // 补齐缺失内置 (vibecoding键盘模式); 内部已 persist (写入最新版本号)
        } else {
            persist()
        }
    }

    // MARK: - 当前选中的 电脑 / 模式
    var currentComputer: Computer? { computers.first { $0.id == currentComputerID } }
    var currentMode: Mode? { currentComputer?.modes.first { $0.id == currentModeID } }

    private var computerIndex: Int? { computers.firstIndex { $0.id == currentComputerID } }
    private func modeIndex(inComputer ci: Int) -> Int? {
        computers[ci].modes.firstIndex { $0.id == currentModeID }
    }

    /// 切换当前电脑: 顺带恢复它上次用的模式。
    func selectComputer(_ id: UUID) {
        guard let target = computers.first(where: { $0.id == id }) else { return }
        currentComputerID = id
        currentModeID = target.lastModeID ?? target.modes.first?.id ?? currentModeID
        persist()
    }

    /// 切换当前模式 (限本电脑内), 并记住为该电脑的「上次模式」。
    func selectMode(_ id: UUID) {
        guard let ci = computerIndex,
              computers[ci].modes.contains(where: { $0.id == id }) else { return }
        currentModeID = id
        computers[ci].lastModeID = id
        persist()
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
    func addComputer(_ c: Computer) {
        computers.append(c)
        persist()
    }

    @discardableResult
    func upsertComputer(name: String, host: String, port: Int, token: String, fingerprint: String = "") -> UUID {
        let nm = name.trimmingCharacters(in: .whitespaces)
        if let i = computers.firstIndex(where: { !host.isEmpty && $0.host == host }) {
            computers[i].port = port
            computers[i].token = token
            computers[i].fingerprint = fingerprint
            if computers[i].name.isEmpty { computers[i].name = nm.isEmpty ? host : nm }
            persist(); return computers[i].id
        }
        if let i = computers.firstIndex(where: { $0.id == currentComputerID }),
           computers[i].host.isEmpty {
            computers[i].host = host
            computers[i].port = port
            computers[i].token = token
            computers[i].fingerprint = fingerprint
            computers[i].name = nm.isEmpty ? host : nm
            persist(); return computers[i].id
        }
        let c = Computer.make(name: nm.isEmpty ? host : nm, host: host, port: port, token: token, fingerprint: fingerprint)
        computers.append(c); persist(); return c.id
    }

    func renameComputer(id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let i = computers.firstIndex(where: { $0.id == id }) else { return }
        computers[i].name = t
        persist()
    }

    func updateComputerConnection(id: UUID, host: String, port: Int, token: String, fingerprint: String = "") {
        guard let i = computers.firstIndex(where: { $0.id == id }) else { return }
        computers[i].host = host
        computers[i].port = port
        computers[i].token = token
        computers[i].fingerprint = fingerprint
        persist()
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

    func deleteComputer(id: UUID) {
        guard computers.count > 1, let idx = computers.firstIndex(where: { $0.id == id }) else { return }
        let goneToken = computers[idx].token
        KeychainToken.delete(id.uuidString)   // 删电脑顺带清掉它在 Keychain 里的令牌
        // 若 SidekeyClient 的 "current" 缓存正是这台的令牌, 一并清掉, 不留陈旧密钥(冷启动不再回填)。
        if !goneToken.isEmpty, KeychainToken.get("current") == goneToken { KeychainToken.delete("current") }
        computers.removeAll { $0.id == id }
        if currentComputerID == id {
            currentComputerID = computers[0].id
            currentModeID = computers[0].lastModeID ?? computers[0].modes.first?.id ?? currentModeID
        }
        persist()
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
        persist()
        return copy.id
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

    // MARK: - 查询 (作用在「当前模式」上)
    var layers: [KeyLayer] { currentMode?.layers ?? DefaultLayout.makeDefault() }
    func layer(_ id: String) -> KeyLayer? { layers.first { $0.id == id } }

    private func mutateCurrentLayers(_ body: (inout [KeyLayer]) -> Void) {
        guard let ci = computerIndex, let mi = modeIndex(inComputer: ci) else { return }
        body(&computers[ci].modes[mi].layers)
        persist()
    }

    // MARK: - 网格占用工具
    private static func occupied(_ layer: KeyLayer, excluding: UUID? = nil) -> Set<Int> {
        var s = Set<Int>()
        for k in layer.keys where k.id != excluding {
            for c in k.col..<(k.col + k.colSpan) {
                for r in k.row..<(k.row + k.rowSpan) { s.insert(c &* 1000 &+ r) }
            }
        }
        return s
    }

    /// 指定矩形区域在网格内、且不和别的键 (excluding 除外) 重叠。
    static func regionFree(in layer: KeyLayer, col: Int, row: Int,
                           colSpan: Int, rowSpan: Int, excluding: UUID?) -> Bool {
        guard col >= 0, row >= 0, colSpan >= 1, rowSpan >= 1,
              col + colSpan <= layer.columns else { return false }
        let occ = occupied(layer, excluding: excluding)
        for c in col..<(col + colSpan) {
            for r in row..<(row + rowSpan) where occ.contains(c &* 1000 &+ r) { return false }
        }
        return true
    }

    private static func firstFreeCell(in layer: KeyLayer) -> (col: Int, row: Int) {
        let occ = occupied(layer)
        var r = 0
        while r < 1000 {
            for c in 0..<max(1, layer.columns) where !occ.contains(c &* 1000 &+ r) { return (c, r) }
            r += 1
        }
        return (0, layer.rowCount)
    }

    /// 找第一个能放下 colSpan×rowSpan 的空区域 (返回左上角); 放不下返回 nil。
    private static func firstFreeRegion(in layer: KeyLayer, colSpan: Int, rowSpan: Int) -> (col: Int, row: Int)? {
        guard colSpan >= 1, rowSpan >= 1, colSpan <= layer.columns else { return nil }
        var r = 0
        while r < 1000 {
            for c in 0...(layer.columns - colSpan) where
                regionFree(in: layer, col: c, row: r, colSpan: colSpan, rowSpan: rowSpan, excluding: nil) {
                return (c, r)
            }
            r += 1
        }
        return nil
    }

    // MARK: - 键的增删改 (当前模式)
    func updateKey(layerID: String, cap: KeyCap) {
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }),
                  let ki = layers[li].keys.firstIndex(where: { $0.id == cap.id }) else { return }
            layers[li].keys[ki] = cap
        }
    }

    /// 在第一个空格子放一个 1×1 新键, 返回它的 id (供编辑器选中)。
    @discardableResult
    func addKey(layerID: String) -> UUID? {
        var newID: UUID?
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            let (c, r) = LayoutStore.firstFreeCell(in: layers[li])
            let cap = KeyCap(label: "新键", code: "space", col: c, row: r)
            newID = cap.id
            layers[li].keys.append(cap)
        }
        return newID
    }

    /// 在本页底部加一整块触控板 (占满宽 × 4 行)。编辑器「加触控板」用。
    @discardableResult
    func addTrackpad(layerID: String) -> UUID? {
        var newID: UUID?
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            guard !layers[li].keys.contains(where: { $0.kind == .trackpad }) else { return }  // 一页只放一个触控板
            let cols = max(1, layers[li].columns)
            let r = layers[li].rowCount   // 放在现有内容下方, 不和别的键冲突
            let cap = KeyCap(label: "触控板", col: 0, row: r, colSpan: cols, rowSpan: 5, kind: .trackpad)
            newID = cap.id
            layers[li].keys.append(cap)
        }
        return newID
    }

    /// 加一个独立鼠标键 (左键/右键)。放在第一个能容下的空位 (4 宽), 放不下就摆到底部。
    @discardableResult
    func addMouseButton(layerID: String, code: String) -> UUID? {
        var newID: UUID?
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            let right = code.lowercased() == "right"
            let span = min(4, max(1, layers[li].columns))
            let pos = LayoutStore.firstFreeRegion(in: layers[li], colSpan: span, rowSpan: 1)
                ?? (col: 0, row: layers[li].rowCount)
            let cap = KeyCap(label: right ? "右键" : "左键", code: right ? "right" : "left",
                             col: pos.col, row: pos.row, colSpan: span, kind: .mouseButton)
            newID = cap.id
            layers[li].keys.append(cap)
        }
        return newID
    }

    /// 复制一个键 (内容相同, 全新 id): 优先放在能容下原尺寸的空区域, 放不下就缩成 1×1。
    @discardableResult
    func duplicateKey(layerID: String, capID: UUID) -> UUID? {
        var newID: UUID?
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }),
                  let src = layers[li].keys.first(where: { $0.id == capID }) else { return }
            var copy = src
            copy.id = UUID()
            if let pos = LayoutStore.firstFreeRegion(in: layers[li], colSpan: src.colSpan, rowSpan: src.rowSpan) {
                copy.col = pos.col; copy.row = pos.row
            } else {
                let (c, r) = LayoutStore.firstFreeCell(in: layers[li])
                copy.col = c; copy.row = r; copy.colSpan = 1; copy.rowSpan = 1
            }
            newID = copy.id
            layers[li].keys.append(copy)
        }
        return newID
    }

    func deleteKey(layerID: String, capID: UUID) {
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            layers[li].keys.removeAll { $0.id == capID }
        }
    }

    /// 把键移到 (col,row); 目标区域被占或越界则不动, 返回是否成功。
    @discardableResult
    func moveKey(layerID: String, capID: UUID, toCol col: Int, toRow row: Int) -> Bool {
        var ok = false
        mutateCurrentLayers { layers in
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
    func resizeKey(layerID: String, capID: UUID, colSpan: Int, rowSpan: Int) -> Bool {
        var ok = false
        mutateCurrentLayers { layers in
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
    func canPlace(layerID: String, capID: UUID, col: Int, row: Int, colSpan: Int, rowSpan: Int) -> Bool {
        guard let l = layer(layerID) else { return false }
        return LayoutStore.regionFree(in: l, col: col, row: row, colSpan: colSpan, rowSpan: rowSpan, excluding: capID)
    }

    // MARK: - 层 / 列 (当前模式)
    func addLayer(named rawName: String) {
        let name = sanitized(rawName, fallback: "layer\(layers.count + 1)")
        mutateCurrentLayers { layers in
            guard !layers.contains(where: { $0.id == name }) else { return }
            layers.append(KeyLayer(id: name, columns: DefaultLayout.columns, keys: []))   // 空页(靠滑动切换, 不放切层键)
        }
    }

    /// 加一个空白「页」(自动唯一 id), 返回它的 id。设置里点「+」加页用。
    @discardableResult
    func addPage() -> String? {
        var newID: String?
        mutateCurrentLayers { layers in
            var id = ""
            repeat { id = "page_\(UUID().uuidString.prefix(6).lowercased())" } while layers.contains { $0.id == id }
            layers.append(KeyLayer(id: id, columns: 12, keys: []))
            newID = id
        }
        return newID
    }

    /// 把某页在顺序里左右移动 (delta -1=左移 / +1=右移)。页 id 不变, 只换数组顺序。
    @discardableResult
    func movePage(id: String, by delta: Int) -> Bool {
        var ok = false
        mutateCurrentLayers { layers in
            guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
            let j = i + delta
            guard j >= 0, j < layers.count else { return }
            layers.swapAt(i, j)
            ok = true
        }
        return ok
    }

    func deleteLayer(id: String) {
        mutateCurrentLayers { layers in
            guard id != "base", layers.count > 1 else { return }
            layers.removeAll { $0.id == id }
        }
    }

    /// 清空某层的所有按键 (层本身保留)。新建模式后想从零搭布局用。
    func clearLayer(id: String) {
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == id }) else { return }
            layers[li].keys = []
        }
    }

    /// 设置某层列数 (1...16)。缩小时若有键会越界则忽略 (避免键跑出网格)。
    func setColumns(layerID: String, _ n: Int) {
        let cols = max(1, min(16, n))
        mutateCurrentLayers { layers in
            guard let li = layers.firstIndex(where: { $0.id == layerID }) else { return }
            if cols < layers[li].columns,
               layers[li].keys.contains(where: { $0.col + $0.colSpan > cols }) { return }
            layers[li].columns = cols
        }
    }

    func addColumn(layerID: String) { setColumns(layerID: layerID, (layer(layerID)?.columns ?? DefaultLayout.columns) + 1) }
    func removeColumn(layerID: String) { setColumns(layerID: layerID, (layer(layerID)?.columns ?? DefaultLayout.columns) - 1) }

    /// 把「当前模式」重置回默认层 (base + more)。
    func resetToDefault() {
        mutateCurrentLayers { layers in layers = DefaultLayout.makeDefault() }
    }

    /// 把「当前模式」的布局恢复到它的初始基线: 先按名精确匹配内置模式(Vibe Coding / vibecoding键盘模式)→ 恢复其布局;
    /// 否则按**名称前缀**匹配 (如「Vibe Coding 副本」→ Vibe Coding) → 副本也能重置回原版;
    /// 都不匹配的纯自建模式 → 通用默认。
    func resetCurrentModeLayout() {
        let name = currentMode?.name ?? ""
        let builtin = BuiltinModes.makeAll().first { $0.name == name }
            ?? BuiltinModes.makeAll().first { !$0.name.isEmpty && name.hasPrefix($0.name) }
        mutateCurrentLayers { layers in
            layers = builtin?.layers ?? DefaultLayout.makeDefault()
        }
    }

    /// 非破坏地补齐内置模式: 每台电脑「按名」缺哪个内置模式就补哪个, 绝不动用户已有模式/编辑。
    /// 内置布局更新**不会**覆盖用户同名模式 —— 优先保住用户数据 (审计【阻断】#1)。
    func addMissingBuiltins() {
        for i in computers.indices {
            let names = Set(computers[i].modes.map(\.name))
            for b in BuiltinModes.makeAll() where !names.contains(b.name) {
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
    private struct Persisted: Codable {
        var computers: [Computer]
        var currentComputerID: UUID
        var currentModeID: UUID
        var builtinVersion: Int?      // 老存档无此字段→nil(当 0); 落后则启动时自动重种内置布局
    }

    private func persist() {
        // 令牌存 Keychain, 不写进明文 JSON。仅当 Keychain 写成功才把 blob 里的令牌抹掉;
        // 写失败(极少见)则保留明文兜底, 绝不丢令牌(否则用户要重新配对)。
        var stripped = computers
        for i in stripped.indices where !stripped[i].token.isEmpty {
            if KeychainToken.set(stripped[i].token, for: stripped[i].id.uuidString) {
                stripped[i].token = ""
            }
        }
        let p = Persisted(computers: stripped,
                          currentComputerID: currentComputerID,
                          currentModeID: currentModeID,
                          builtinVersion: BuiltinModes.version)
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: LayoutStore.storeKey)
        }
    }

    /// 读取存档; v5 优先; 没有则从 v4 迁移 (保留电脑/连接, 缺的内置模式由 addMissingBuiltins 非破坏补齐);
    /// 再没有则从 v3 迁移 (保留电脑/模式名, 布局重置); 都没有就种一份全新默认 (种入全部内置模式)。
    private static func load(from defaults: UserDefaults) -> Persisted {
        if let data = defaults.data(forKey: storeKey),
           var p = try? JSONDecoder().decode(Persisted.self, from: data),
           !p.computers.isEmpty {
            // 填回 Keychain 里的令牌; Keychain 没有就沿用 blob 里的(旧明文存档 → 下次 persist 自动迁进 Keychain)。
            for i in p.computers.indices {
                if let t = KeychainToken.get(p.computers[i].id.uuidString), !t.isEmpty {
                    p.computers[i].token = t
                }
            }
            return p
        }
        // v4 → v5: 用户的电脑/模式/布局**原样保留** (v4 已是网格模型, 直接可用);
        // 缺的内置模式由 init 的 addMissingBuiltins() 非破坏补齐 (不删用户模式)。审计【阻断】#1。
        if let data = defaults.data(forKey: legacyV4Key),
           var v4 = try? JSONDecoder().decode(Persisted.self, from: data),
           !v4.computers.isEmpty {
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
        let computer = Computer.make(name: "我的电脑")
        let modeID = computer.modes.first?.id ?? UUID()
        return Persisted(computers: [computer], currentComputerID: computer.id, currentModeID: modeID,
                         builtinVersion: BuiltinModes.version)
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
