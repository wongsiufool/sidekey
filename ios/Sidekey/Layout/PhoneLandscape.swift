import CoreGraphics

/// 手机屏横屏 (§4.1.2, v1.7): 每一页按触控板的位置分三种情况, 纯计算, 不依赖界面。
enum LandscapeKind: Equatable {
    case noTrackpad          // A: 这一页没有 .trackpad 键
    case wholeRowTrackpad    // B: 触控板占满连续的整行 (第 0 列到最后一列), 没有别的键和这些行相交 (例如默认 Vibe Coding)
    case mixed               // C: 有触控板但不符合 B (例如 Codex Micro): 触控板格子当普通格子
}

/// B 类放不下时的单区选择 (§3.5): 只显示按键, 或只显示触控板 (+ 左右鼠标键)。
enum SingleZone: Equatable { case keys, trackpad }

struct PhoneLandscapePlan: Equatable {
    enum Presentation: Equatable {
        case grid                          // A / C: 整页网格, 触控板格子当普通格子
        case stacked([Block])              // B 正常: 按键行固定 40 pt + 触控板占剩余高度
        case keysOnly                      // B 单区: 去掉触控板行后的按键, 再按 §3.6 切子页
        case trackpadOnly                  // 单区: 触控板 + 左右鼠标键 (B 类放不下按键行; 或宽度不够显示这一页的列数时用户切到触控板)
        case tooSmallForTrackpad(minWidth: CGFloat, minHeight: CGFloat)   // 「只显示触控板」时连 160 宽 / 80 高的触控板都放不下: 占位, 侧栏仍可切回键盘 (不压缩触控板)
    case tooNarrow(required: CGFloat, trackpadAvailable: Bool)  // 宽度不够放下这一页的列数 (每格 ≥ 20 pt 不降): 显示「窗口太窄」占位, 不缩键
    }
    struct Block: Equatable {
        enum Kind: Equatable { case keys(Range<Int>), trackpad }
        var kind: Kind
        var height: CGFloat
    }

    var kind: LandscapeKind
    var presentation: Presentation
    /// 实际用来渲染的键 (keysOnly 时已去掉触控板行并把行号按顺序重排; 其余是原样)。
    var keys: [KeyCap]
    var rowCount: Int
    /// 子页 (grid / keysOnly)。滑动只翻真正的页; 这一页有触控板时翻子页只能点圆点 (§3.6、§4.1.2)。
    var subpages: [Subpage]
    var trackpadHeight: CGFloat?
    /// 单区模式: 侧栏里一直要有「键盘 / 触控板」切换按钮。
    var needsZoneToggle: Bool
    /// trackpadOnly 时一起显示的鼠标左 / 右键。
    var mouseButtons: [KeyCap]
    /// 子页入口 (圆点) 是否要出现。
    var hasSubpageDots: Bool { subpages.count > 1 }
}

enum PhoneLandscape {
    static let keyRowHeight: CGFloat = SubpageSplitter.minRowHeight   // 40
    static let rowGap: CGFloat = SubpageSplitter.rowGap               // 8
    static let minTrackpadHeight: CGFloat = 80                        // B 类触控板最低高度
    static let minTrackpadWidth: CGFloat = 160                        // 触控板最小宽度 (§3.5)
    static let mouseRowHeight: CGFloat = 56                           // 单区「只显示触控板」时下方鼠标键行
    static let minCellWidth: CGFloat = 20                             // 每格最小宽度 (§3.5), 不降
    static let columnGap: CGFloat = 8

    /// 这一页的列数需要的最小按键区宽度: 列数 × 20 + (列数 − 1) × 8。
    static func minGridWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * minCellWidth + CGFloat(max(0, columns - 1)) * columnGap
    }

    /// 侧栏宽度: 宽度不够按键区时先收窄侧栏 (60 → 48, 命中区仍 ≥ 44), 再不够才走占位 (§3.5 回退顺序第 1 步)。
    static let sideBarWide: CGFloat = 60
    static let sideBarNarrow: CGFloat = 48
    static func sideBarWidth(containerWidth: CGFloat, columns: Int) -> CGFloat {
        containerWidth - 2 * sideBarWide >= minGridWidth(columns: columns) ? sideBarWide : sideBarNarrow
    }

    static func classify(keys: [KeyCap], columns: Int) -> LandscapeKind {
        guard let tp = keys.first(where: { $0.kind == .trackpad }) else { return .noTrackpad }
        let rows = tp.row..<(tp.row + tp.rowSpan)
        let whole = tp.col == 0 && tp.colSpan >= columns && keys.filter { $0.kind == .trackpad }.count == 1
        let clear = !keys.contains { $0.kind != .trackpad && $0.row < rows.upperBound && rows.lowerBound < $0.row + $0.rowSpan }
        return whole && clear ? .wholeRowTrackpad : .mixed
    }

    /// 「只显示触控板」: 触控板高 = 可用高度 − 鼠标键行 − 行距, 宽 = 可用宽度; 低于 80 高 / 160 宽的下限就不压缩, 改为「窗口太小」占位。
    private static func trackpadOnlyPlan(kind: LandscapeKind, keys: [KeyCap], total: Int,
                                         availableHeight: CGFloat, availableWidth: CGFloat) -> PhoneLandscapePlan {
        let tpHeight = availableHeight - mouseRowHeight - rowGap
        if tpHeight < minTrackpadHeight || availableWidth < minTrackpadWidth {
            return PhoneLandscapePlan(kind: kind, presentation: .tooSmallForTrackpad(minWidth: minTrackpadWidth, minHeight: minTrackpadHeight + mouseRowHeight + rowGap),
                                      keys: keys, rowCount: total, subpages: [], trackpadHeight: nil, needsZoneToggle: true, mouseButtons: [])
        }
        return PhoneLandscapePlan(kind: kind, presentation: .trackpadOnly, keys: keys, rowCount: total, subpages: [],
                                  trackpadHeight: tpHeight, needsZoneToggle: true, mouseButtons: mouseButtons(in: keys))
    }

    /// - Parameters:
    ///   - availableHeight: 按键区可用高度 (已扣顶 / 底留白; 侧栏在左右, 不占高度)
    ///   - zone: B 类进入单区后用户选的区
    static func plan(keys: [KeyCap], columns: Int, rowCount: Int, availableHeight: CGFloat,
                     availableWidth: CGFloat = .infinity, zone: SingleZone = .keys) -> PhoneLandscapePlan {
        let kind = classify(keys: keys, columns: columns)
        let total = max(1, rowCount)

        // 宽度不够 (每格 20 pt 的下限不降): 有触控板的页可以切到「只显示触控板」; 否则显示「窗口太窄」占位。
        let needed = minGridWidth(columns: columns)
        if availableWidth < needed {
            let hasTrackpad = keys.contains { $0.kind == .trackpad }
            if hasTrackpad, zone == .trackpad {
                return trackpadOnlyPlan(kind: kind, keys: keys, total: total, availableHeight: availableHeight, availableWidth: availableWidth)
            }
            return PhoneLandscapePlan(kind: kind, presentation: .tooNarrow(required: needed, trackpadAvailable: hasTrackpad), keys: keys, rowCount: total, subpages: [],
                                      trackpadHeight: nil, needsZoneToggle: hasTrackpad, mouseButtons: [])
        }

        if kind == .wholeRowTrackpad, let tp = keys.first(where: { $0.kind == .trackpad }) {
            let keyRows = total - tp.rowSpan
            // 按键行固定 40 pt, 行距 8; 触控板和按键行之间也是一个行距 → 触控板高 = 可用高度 − 按键行数 × (40 + 8)
            let tpHeight = availableHeight - CGFloat(keyRows) * (keyRowHeight + rowGap)
            if tpHeight >= minTrackpadHeight {
                var blocks: [PhoneLandscapePlan.Block] = []
                if tp.row > 0 { blocks.append(.init(kind: .keys(0..<tp.row), height: rowsHeight(tp.row))) }
                blocks.append(.init(kind: .trackpad, height: tpHeight))
                let after = (tp.row + tp.rowSpan)..<total
                if !after.isEmpty { blocks.append(.init(kind: .keys(after), height: rowsHeight(after.count))) }
                return PhoneLandscapePlan(kind: kind, presentation: .stacked(blocks), keys: keys, rowCount: total, subpages: [],
                                          trackpadHeight: tpHeight, needsZoneToggle: false, mouseButtons: [])
            }
            // 连 80 pt 都留不出来: 进单区, 只改显示, 不改存档
            switch zone {
            case .keys:
                let (kept, rows) = removingTrackpadRows(keys: keys, trackpad: tp, rowCount: total)
                let subs = SubpageSplitter.split(keys: kept, totalRows: rows, maxRows: max(1, SubpageSplitter.rowsThatFit(height: availableHeight)))
                return PhoneLandscapePlan(kind: kind, presentation: .keysOnly, keys: kept, rowCount: rows, subpages: subs,
                                          trackpadHeight: nil, needsZoneToggle: true, mouseButtons: [])
            case .trackpad:
                return trackpadOnlyPlan(kind: kind, keys: keys, total: total, availableHeight: availableHeight, availableWidth: availableWidth)
            }
        }

        // A / C: 整页网格 (C 的触控板格子当普通格子, 行高和同一行的键一样)
        let fitsAll = availableHeight >= rowsHeight(total)
        let n = fitsAll ? total : max(1, SubpageSplitter.rowsThatFit(height: availableHeight))
        let subs = SubpageSplitter.split(keys: keys, totalRows: total, maxRows: n)
        return PhoneLandscapePlan(kind: kind, presentation: .grid, keys: keys, rowCount: total, subpages: subs,
                                  trackpadHeight: nil, needsZoneToggle: false, mouseButtons: [])
    }

    static func rowsHeight(_ rows: Int) -> CGFloat {
        CGFloat(rows) * keyRowHeight + CGFloat(max(0, rows - 1)) * rowGap
    }

    /// 「只显示按键」: 去掉触控板占的那几行, 其余键保持原来的上下顺序、列位置和跨度, 行号按顺序重排。
    static func removingTrackpadRows(keys: [KeyCap], trackpad tp: KeyCap, rowCount: Int) -> ([KeyCap], Int) {
        let removed = tp.rowSpan
        let end = tp.row + tp.rowSpan
        let kept = keys.filter { $0.id != tp.id }.map { k -> KeyCap in
            var k = k
            if k.row >= end { k.row -= removed }
            return k
        }
        return (kept, max(0, rowCount - removed))
    }

    /// 单区「只显示触控板」时一起显示的左 / 右键: 取这一页里的鼠标键, 按 code 去重, 缺哪个补哪个 (固定左、右顺序)。
    static func mouseButtons(in keys: [KeyCap]) -> [KeyCap] {
        ["left", "right"].map { code in
            keys.first { $0.kind == .mouseButton && $0.code.lowercased() == code }
                ?? KeyCap(label: code == "left" ? "左键" : "右键", code: code, kind: .mouseButton)
        }
    }
}
