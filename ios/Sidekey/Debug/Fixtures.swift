#if DEBUG
import Foundation

/// 横屏回退的验收夹具 (只在 DEBUG 编译): `--fixture <名字>` 在当前电脑上建一个同名模式并选中, 用来在模拟器里实际操作各种回退界面。
enum DebugFixtures {
    static func layers(named name: String) -> [KeyLayer]? {
        func k(_ label: String, _ col: Int, _ row: Int, colSpan: Int = 1, rowSpan: Int = 1, kind: KeyCap.Kind = .normal, code: String = "") -> KeyCap {
            KeyCap(label: label, code: code.isEmpty ? label.lowercased() : code, col: col, row: row, colSpan: colSpan, rowSpan: rowSpan, kind: kind)
        }
        switch name {
        case "wide18":        // 18 列: Duo 外屏横屏 (容器 594) 侧栏 60 放不下 (474 < 496), 收窄到 48 就放得下 (498)
            return [KeyLayer(id: "base", columns: 18, keys: (0..<18).map { k("\($0)", $0, 0) } + (0..<18).map { k("b\($0)", $0, 1) })]
        case "wide20":        // 20 列、没有触控板: 侧栏收窄也放不下 (498 < 552) → 「窗口太窄」占位 (没有「切到触控板」)
            return [KeyLayer(id: "base", columns: 20, keys: (0..<20).map { k("\($0)", $0, 0) } + (0..<20).map { k("b\($0)", $0, 1) })]
        case "wide20tp":      // 20 列、有触控板: 宽度不够 → 占位 + 侧栏「触控板」切换
            return [KeyLayer(id: "base", columns: 20, keys: [KeyCap(label: "触控板", col: 0, row: 0, colSpan: 20, rowSpan: 2, kind: .trackpad)]
                             + (0..<20).map { k("k\($0)", $0, 2) })]
        case "subpages":      // 30 行 → 横屏切成多个子页 (>3 个时收成「i/n」列表), 含一个跨 3 行的高键
            var keys: [KeyCap] = []
            for r in 0..<30 { keys.append(k("r\(r)a", 0, r, colSpan: 3)); if !(5...7).contains(r) { keys.append(k("r\(r)b", 3, r, colSpan: 3)) } }
            keys.append(k("TALL", 3, 5, colSpan: 3, rowSpan: 3))
            return [KeyLayer(id: "base", columns: 6, keys: keys)]
        case "tallpage":      // 一个高 20 行的键: 超高子页, 压行高 / 滚动
            return [KeyLayer(id: "base", columns: 4, keys: [k("A", 0, 0, colSpan: 4), k("HUGE", 0, 1, colSpan: 4, rowSpan: 20), k("Z", 0, 21, colSpan: 4)])]
        case "singlezone":    // B 类: 触控板 2 行 + 7 行按键 → 触控板放不下 80 pt → 单区
            var keys = [KeyCap(label: "触控板", col: 0, row: 0, colSpan: 4, rowSpan: 2, kind: .trackpad)]
            keys += (0..<7).map { k("key\($0)", 0, 2 + $0, colSpan: 2) } + (0..<7).map { k("rk\($0)", 2, 2 + $0, colSpan: 2) }
            keys.append(KeyCap(label: "左键", code: "left", col: 0, row: 9, colSpan: 2, kind: .mouseButton))
            return [KeyLayer(id: "base", columns: 4, keys: keys)]
        case "mixed":         // 混排 (C): 触控板在中间一格, 周围都是键, 有跨行 / 跨列键; 第二页用来验证触控板页不被横滑翻页
            return [KeyLayer(id: "p2", columns: 5, keys: [k("PAGE2", 0, 0, colSpan: 5)]), KeyLayer(id: "base", columns: 5, keys: [
                k("A", 0, 0), k("B", 1, 0), KeyCap(label: "触控板", col: 2, row: 0, colSpan: 2, rowSpan: 2, kind: .trackpad), k("C", 4, 0, rowSpan: 2),
                k("D", 0, 1), k("E", 1, 1), k("F", 0, 2, colSpan: 2), k("G", 2, 2), k("H", 3, 2), k("I", 4, 2),
                KeyCap(label: "左键", code: "left", col: 0, row: 3, colSpan: 2, kind: .mouseButton), KeyCap(label: "右键", code: "right", col: 2, row: 3, colSpan: 3, kind: .mouseButton),
            ])].reversed()
        case "twopages":      // 两页: 删除当前页后窗口要回退到有效页
            return [KeyLayer(id: "base", columns: 4, keys: [k("P1", 0, 0, colSpan: 2), KeyCap(label: "→P2", col: 2, row: 0, colSpan: 2, kind: .layer, targetLayer: "p2")]),
                    KeyLayer(id: "p2", columns: 4, keys: [k("P2", 0, 0, colSpan: 2), KeyCap(label: "→P1", col: 2, row: 0, colSpan: 2, kind: .layer, targetLayer: "base")])]
        case "legacybounds":  // M2: 原键位里有超出范围的旧键 (第 10001 行) → 内屏不生成大屏键位, 编辑器标明「正在编辑原键位」
            return [KeyLayer(id: "base", columns: 4, keys: [k("A", 0, 0), k("B", 1, 0), k("旧", 0, 10_001)])]
        default: return nil
        }
    }
}

extension LayoutStore {
    /// DEBUG: 用夹具新建一个模式并选中 (返回新模式 id)。
    func installFixture(named name: String) -> UUID? {
        guard let ls = DebugFixtures.layers(named: name), let id = addMode(named: "fx-" + name) else { return nil }
        setLayersForDebug(mode: id, layers: ls)
        selectMode(id)
        return id
    }
}
#endif
