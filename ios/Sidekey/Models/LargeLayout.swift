import Foundation
import CryptoKit

/// 两套键位 (§1、§6.3): 原键位 (手机屏) / 大屏键位 (内屏)。
enum LayoutSet: String, Codable, Hashable { case original, large }

/// 编辑 / 查询的明确目标: 哪台电脑、哪个模式、哪套键位 (§6.3: 不依赖全局的当前电脑 / 模式)。
struct LayoutTarget: Hashable {
    var computer: UUID
    var mode: UUID
    var set: LayoutSet
}

/// 一个模式的大屏键位 (§6.1): 页 (已去掉触控板和鼠标键) + 这个模式唯一的一组鼠标键 (左键、右键, 固定在触控板旁边, 所有页共用)。
/// 存在独立的 `sidekey.large.v1` 里, 按「电脑 id + 模式 id」索引; 没有记录 = 还没生成 (不等于「空布局」)。
struct LargeLayout: Codable, Equatable {
    var layers: [KeyLayer]
    var mouseButtons: [KeyCap]
    /// 用户编辑过 (生成之后在大屏编辑器里改过)。只做记录: 已生成的大屏键位本来就不会被自动覆盖, 只有手动「从原键位重新生成」/「两套都重置」会替换。
    var edited: Bool = false
}

/// 大屏键位的生成规则 (§6.1)。纯函数: 同样的输入一定得到同样的结果 (含补上的鼠标键 id), 与屏幕尺寸无关。
enum LargeLayoutGenerator {
    /// 只有网格模式生成大屏键位; 笔记本键盘模式 (§4.9) 和本版不认识的模式类型不生成。
    static func supports(_ mode: Mode) -> Bool { mode.kind == .grid }

    static func generate(from mode: Mode) -> LargeLayout? {
        guard supports(mode), LayoutBounds.layersFit(mode.layers) else { return nil }   // 原键位有超出范围的键: 不生成 (不裁、不挪)
        if let factory = factoryVibe(layers: mode.layers, seed: mode.id) { return factory }   // 第 10 条: 出厂 Vibe 用专门的大屏键位
        return generate(layers: mode.layers, seed: mode.id)
    }

    // MARK: - 第 10 条: 内置 Vibe Coding 的出厂大屏键位

    /// 原键位和出厂 Vibe 一致 (不比较 id) 时, 返回专门为内屏排的 12 列 × 5 行、18 个键; 否则 nil (照第 1–8 条推导, 不补键)。
    /// SPACE / Backspace / Typeless / ENTER / ESC 沿用原键位的 id; 新加的 13 个键的 id 由 `seed` (模式 id) 确定性派生。
    static func factoryVibe(layers: [KeyLayer], seed: UUID) -> LargeLayout? {
        guard isFactoryVibe(layers), let base = layers.first else { return nil }
        func orig(_ code: String, mods: [String] = []) -> KeyCap? {
            base.keys.first { $0.kind == .normal && $0.code == code && $0.mods == mods }
        }
        guard var space = orig("space"), var bksp = orig("backspace"), var typeless = orig("", mods: ["lctrl"]),
              var enter = orig("enter"), var esc = orig("esc") else { return nil }
        func new(_ name: String, _ k: KeyCap) -> KeyCap { var c = k; c.id = derivedID("vibe.factory.\(name)", seed: seed); return c }
        func cmd(_ t: String, col: Int) -> KeyCap {
            new(t, KeyCap(label: t, col: col, row: 1, colSpan: 3, tint: .coral, sendText: t))   // 斜杠命令, 样式同「vibecoding键盘模式」
        }
        func place(_ k: inout KeyCap, col: Int, row: Int) { k.col = col; k.row = row; k.colSpan = 4; k.rowSpan = 1 }
        place(&space, col: 4, row: 3); place(&bksp, col: 8, row: 3)
        place(&typeless, col: 0, row: 4); place(&enter, col: 4, row: 4); place(&esc, col: 8, row: 4)
        let keys: [KeyCap] = [
            // 行 0: ⌘ 组合 (primary = Mac ⌘ / 其他平台 Ctrl)
            new("cmdC", KeyCap(label: "⌘C", code: "c", mods: ["primary"], col: 0, row: 0, colSpan: 3)),
            new("cmdV", KeyCap(label: "⌘V", code: "v", mods: ["primary"], col: 3, row: 0, colSpan: 3)),
            new("cmdA", KeyCap(label: "⌘A", code: "a", mods: ["primary"], col: 6, row: 0, colSpan: 3)),
            new("cmdZ", KeyCap(label: "⌘Z", code: "z", mods: ["primary"], col: 9, row: 0, colSpan: 3)),
            // 行 1: 斜杠命令
            cmd("/clear", col: 0), cmd("/compact", col: 3), cmd("/usage", col: 6), cmd("/btw", col: 9),
            // 行 2: 权限 / Effort / ↑ / ↓
            new("permission", KeyCap(label: "权限", col: 0, row: 2, colSpan: 3, kind: .permission)),
            new("effort", KeyCap(label: "Effort", col: 3, row: 2, colSpan: 3, kind: .effort)),
            new("up", KeyCap(label: "↑", code: "up", col: 6, row: 2, colSpan: 3)),
            new("down", KeyCap(label: "↓", code: "down", col: 9, row: 2, colSpan: 3)),
            // 行 3: Tab (占原来左键的位置) / SPACE / Backspace
            new("tab", KeyCap(label: "Tab", code: "tab", col: 0, row: 3, colSpan: 4)),
            space, bksp,
            // 行 4: Typeless / ENTER / ESC
            typeless, enter, esc,
        ]
        // 鼠标键照第 5 条: 左键取自原键位, 右键补默认的
        let mice = generate(layers: layers, seed: seed).mouseButtons
        return LargeLayout(layers: [KeyLayer(id: base.id, columns: 12, keys: keys)], mouseButtons: mice, edited: false)
    }

    /// 和出厂 Vibe 原键位一致 (逐键比较除 id 以外的全部属性, 与键的先后顺序无关)。
    static func isFactoryVibe(_ layers: [KeyLayer]) -> Bool {
        let factory = BuiltinModes.vibe().layers
        guard layers.count == factory.count else { return false }
        return zip(layers, factory).allSatisfy { a, b in
            a.id == b.id && a.columns == b.columns && withoutIDs(a.keys) == withoutIDs(b.keys)
        }
    }

    private static func withoutIDs(_ keys: [KeyCap]) -> [KeyCap] {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        return keys.map { var k = $0; k.id = zero; return k }
            .sorted { ($0.row, $0.col, $0.label) < ($1.row, $1.col, $1.label) }
    }

    /// `seed`: 只用来派生「补上的鼠标键」的 id, 让结果可重复 (一般传模式 id)。
    static func generate(layers: [KeyLayer], seed: UUID) -> LargeLayout {
        var mice: [KeyCap] = []
        var outLayers: [KeyLayer] = []
        for layer in layers {
            // 第 2、3 条: 移出触控板和鼠标键 (页里没有触控板时也移出鼠标键)
            let removed = layer.keys.filter(isRemoved)
            let kept = layer.keys.filter { !isRemoved($0) }
            // 第 5 条: 收集鼠标键, 按左 / 右去重, 标签取第一次出现的
            for k in removed where k.kind == .mouseButton {
                let side = buttonSide(k)
                if !mice.contains(where: { buttonSide($0) == side }) { mice.append(k) }
            }
            // 第 4 条: 只压缩因为移除才新出现的空行 (原本就空的行保留)
            let before = coveredRows(layer.keys), after = coveredRows(kept)
            let dropped = before.subtracting(after).sorted()
            var l = layer
            l.keys = kept.map { k in
                var c = k
                c.row = k.row - dropped.filter { $0 < k.row }.count
                return c
            }
            outLayers.append(l)        // 第 7 条: 整页只有触控板 / 鼠标键 → 空页保留 (可能有 .layer 键跳到这一页)
        }
        // 第 5 条: 缺哪个补哪个, 固定顺序 左键、右键
        let left = mice.first { buttonSide($0) == "left" } ?? defaultButton("left", seed: seed)
        let right = mice.first { buttonSide($0) == "right" } ?? defaultButton("right", seed: seed)
        return LargeLayout(layers: outLayers, mouseButtons: [left, right], edited: false)
    }

    private static func isRemoved(_ k: KeyCap) -> Bool { k.kind == .trackpad || k.kind == .mouseButton }

    /// 与 `MouseKeyButton` 一致: code 为 "right" 是右键, 其余都按左键。
    static func buttonSide(_ k: KeyCap) -> String { k.code.lowercased() == "right" ? "right" : "left" }

    /// 被任何键覆盖的行 (跨行键覆盖的每一行都算)。
    static func coveredRows(_ keys: [KeyCap]) -> Set<Int> {
        var s = Set<Int>()
        for k in keys { for r in k.row..<(k.row + max(1, k.rowSpan)) { s.insert(r) } }
        return s
    }

    private static func defaultButton(_ side: String, seed: UUID) -> KeyCap {
        KeyCap(id: derivedID("large.mouse.\(side)", seed: seed),
               label: side == "right" ? "右键" : "左键", code: side, kind: .mouseButton)
    }

    /// 由种子派生的固定 UUID (SHA-256 前 16 字节, 按 v4 格式置位), 保证可重复。
    static func derivedID(_ name: String, seed: UUID) -> UUID {
        let digest = SHA256.hash(data: Data((seed.uuidString + "|" + name).utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// 键位几何的合法范围 (§6.4 第 5 条「几何范围读写一致」): 生成、编辑、保存、读取共用这一套。
/// 远大于能编辑出来的布局, 又保证坐标 + 跨度不会溢出。
enum LayoutBounds {
    static let maxColumns = 256
    static let maxCoordinate = 10_000

    /// 网格里的键: 坐标、跨度在范围内, 并且整个键在网格内 (col + colSpan ≤ columns, row + rowSpan ≤ 上限)。
    static func keyFits(_ k: KeyCap, columns: Int) -> Bool {
        valuesInRange(k) && k.col + k.colSpan <= columns && k.row + k.rowSpan <= maxCoordinate
    }

    /// 只检查数值 (不在网格里的键, 例如大屏键位的鼠标键组)。
    static func valuesInRange(_ k: KeyCap) -> Bool {
        let m = maxCoordinate
        return (0...m).contains(k.col) && (0...m).contains(k.row) && (1...m).contains(k.colSpan) && (1...m).contains(k.rowSpan)
    }

    /// 起点 + 跨度 (跨度 < 1 按 1 算), 溢出时取 Int.max。旧数据里坐标可能任意大, 算边界一律用它。
    static func end(_ start: Int, _ span: Int) -> Int {
        let (v, o) = start.addingReportingOverflow(max(1, span))
        return o ? Int.max : v
    }

    static func layerFits(_ l: KeyLayer) -> Bool {
        (1...maxColumns).contains(l.columns) && l.keys.allSatisfy { keyFits($0, columns: l.columns) }
    }

    /// 一个模式的全部页都在范围内 (有超出范围的旧数据时不生成大屏键位, 原键位照常保留可用)。
    static func layersFit(_ layers: [KeyLayer]) -> Bool { layers.allSatisfy(layerFits) }
}
