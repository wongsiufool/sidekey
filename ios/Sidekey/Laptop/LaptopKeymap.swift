import Foundation
import CoreGraphics

// 笔记本键盘模式 (§4.9) 的键表、发送规则、粘滞修饰键和排版。
// 键表数据在 LaptopKeymapData.swift, 由需求附录 appendix-laptop-keymap.md 生成 (实现以附录为准)。

/// 电脑的排法 (§4.9「排法跟电脑走」): 读连接就绪消息 `ready.platform`, 按电脑分别记住。
enum LaptopPlatform: String, Codable, Equatable {
    case mac, windows
    /// 电脑端 `platform.system()`: Darwin / Windows / Linux …; 认不出来返回 nil。
    init?(serverPlatform s: String) {
        switch s.lowercased() {
        case "darwin": self = .mac
        case "windows": self = .windows
        default: return nil
        }
    }
}

enum LaptopModifier: String, CaseIterable, Equatable {
    case shift, ctrl, alt, cmd, win
}

/// 一个键按下时做什么。
enum LaptopAction: Equatable {
    case key(String)                 // 发一条一次性 key 消息, 键码就是电脑端认识的键名
    case modifier(LaptopModifier)    // 修饰键: 只粘住, 不发消息
    case fnLayer                     // App 自己的 fn 层: 只能粘住一次, 不进 mods
}

struct LaptopKey: Equatable, Identifiable {
    let id: String                   // 稳定键标识 (附录)
    let width: Double                // 单位键宽的倍数
    let normal: LaptopAction
    let fn: LaptopAction?            // fn 层; 修饰键 / fn 本身为 nil
    let symbol: String               // 键帽主文字 (符号或字母; 空格键为空)
    let word: String?                // 功能键下方的小字 (delete / return / shift …)
    let shiftHint: String?           // 数字、标点键上方的 Shift 符号 (只显示)
    let repeats: Bool                // 长按连发 (⌫、方向键、空格)

    /// 左右同名修饰键共用一个状态 (§4.9)。
    var modifier: LaptopModifier? { if case .modifier(let m) = normal { return m }; return nil }
    var isFn: Bool { normal == .fnLayer }
}

/// 键表的形态。半折键表属于 M4。
enum LaptopTable: Equatable { case portrait, split }

enum LaptopKeymap {
    static func rows(_ p: LaptopPlatform, portrait: Bool) -> (left: [[LaptopKey]], right: [[LaptopKey]]) {
        switch (p, portrait) {
        case (.mac, true): return (macPortrait, [])
        case (.windows, true): return (winPortrait, [])
        case (.mac, false): return (macSplitLeft, macSplitRight)
        case (.windows, false): return (winSplitLeft, winSplitRight)
        }
    }

    /// 按下一个键时真正发出的键码和 mods (§4.9「按键怎么发」): fn 粘住时用 fn 层键码; 粘住的修饰键放进 mods。
    /// 修饰键和 fn 本身返回 nil (不发消息)。
    /// 只粘住 Shift、按的是数字或标点 (键帽上方有上档小字) 时, 直接发上档字符本身, 不带 shift (§4.9, M3f 实测后定):
    /// Mac 上电脑端的按键库对「数字 / 标点 + shift」打不出上档符号。上档字符按美式键盘, 和键帽上方的小字一致。
    /// 字母照旧发「字母 + shift」; Shift 和其他修饰键一起粘住时照旧发「键码 + 全部修饰键」; fn 层优先 (fn 粘住时 Shift 照常进 mods)。
    static func message(for key: LaptopKey, snapshot: StickyModifiers.Snapshot) -> (code: String, mods: [String])? {
        let action = snapshot.fn ? (key.fn ?? key.normal) : key.normal
        guard case .key(let code) = action else { return nil }
        if !snapshot.fn, snapshot.mods == [.shift], let shifted = key.shiftHint { return (shifted, []) }
        let order: [LaptopModifier] = [.shift, .ctrl, .alt, .cmd, .win]
        return (code, order.filter { snapshot.mods.contains($0) }.map(\.rawValue))
    }
}

/// 修饰键粘滞 (§4.9, v1.7 改写)。纯状态机, 按窗口各一份, 时间由调用方传入。
/// - ⇧ ⌃ ⌥ ⌘ (⊞): 点一下粘住一次; 0.4 秒内连点两下锁定; 再点一下取消。fn 只能粘住一次。可以同时粘住几个。
/// - 「一次」的预留: 按键手势一开始就预留给这个手势, 其他手指同时按下的键拿不到;
///   手势第一次真正发出消息时用掉; 发出之前被取消就退还; 已经发出 / 开始连发后被取消不退还。
/// - 长按连发整串用手势开始时的快照。
struct StickyModifiers: Equatable {
    enum State: Equatable { case off, once, locked }

    struct Snapshot: Equatable {
        var mods: Set<LaptopModifier> = []
        var fn = false
        /// 这个快照里用了「一次」的那几个 (用掉 / 退还时用)。
        var reservedOnce: Set<LaptopModifier> = []
        var reservedFn = false
    }

    static let doubleTapWindow: TimeInterval = 0.4

    private(set) var states: [LaptopModifier: State] = [:]
    private(set) var fnOnce = false
    private var lastTap: [LaptopModifier: TimeInterval] = [:]
    /// 当前持有「一次」预留的手势。
    private(set) var reservedBy: UUID?
    private var reservation = Snapshot()

    func state(_ m: LaptopModifier) -> State { states[m] ?? .off }
    var isEmpty: Bool { !fnOnce && states.values.allSatisfy { $0 == .off } }

    /// 点修饰键本身 (不发消息)。
    mutating func tap(_ m: LaptopModifier, at t: TimeInterval) {
        switch state(m) {
        case .off:
            states[m] = .once
        case .once:
            states[m] = (t - (lastTap[m] ?? -.infinity) <= Self.doubleTapWindow) ? .locked : .off
        case .locked:
            states[m] = .off
        }
        lastTap[m] = t
    }

    /// fn 只能粘住一次: 再点一下取消。
    mutating func tapFn() { fnOnce.toggle() }

    /// 按键手势开始: 拍快照。锁定的修饰键所有手势都有; 「一次」(含 fn) 只给最先按下、还没有预留的手势。
    mutating func begin(_ gesture: UUID) -> Snapshot {
        var snap = Snapshot()
        snap.mods = Set(states.filter { $0.value == .locked }.map(\.key))
        guard reservedBy == nil else { return snap }
        let once = Set(states.filter { $0.value == .once }.map(\.key))
        guard !once.isEmpty || fnOnce else { return snap }
        snap.mods.formUnion(once)
        snap.fn = fnOnce
        snap.reservedOnce = once
        snap.reservedFn = fnOnce
        reservedBy = gesture
        reservation = snap
        return snap
    }

    /// 这个手势第一次真正发出消息: 预留的「一次」用掉。
    mutating func didSend(_ gesture: UUID) {
        guard reservedBy == gesture else { return }
        for m in reservation.reservedOnce where states[m] == .once { states[m] = .off }
        if reservation.reservedFn { fnOnce = false }
        reservedBy = nil
        reservation = Snapshot()
    }

    /// 手势结束 (松手或被取消)。还没发出就结束 = 退还预留 (状态本来就没动, 只解除预留)。
    mutating func end(_ gesture: UUID) {
        guard reservedBy == gesture else { return }
        reservedBy = nil
        reservation = Snapshot()
    }

    /// 切电脑、切模式、切到后台、断线时全部清空 (含锁定); 旋转、调换、开合时保留。
    mutating func clearAll() {
        states = [:]; fnOnce = false; lastTap = [:]; reservedBy = nil; reservation = Snapshot()
    }

    /// 逐项状态 (摘要展开的列表、屏幕阅读器用), 例如「⌘ 粘住一次」「⇧ 已锁定」。
    func summaryItems(_ p: LaptopPlatform) -> [String] {
        var items: [String] = []
        for m in LaptopModifier.allCases {
            let s = state(m)
            guard s != .off else { continue }
            items.append("\(Self.glyph(m, p)) \(s == .locked ? String(localized: "已锁定") : String(localized: "粘住一次"))")
        }
        if fnOnce { items.append("fn " + String(localized: "粘住一次")) }
        return items
    }

    /// 摘要 (§4.9): 一个时写「⌘ 粘住一次」, 两个以上收成「3 个修饰键」(点开看列表)。
    func summary(_ p: LaptopPlatform) -> (text: String, count: Int)? {
        let items = summaryItems(p)
        guard !items.isEmpty else { return nil }
        return items.count == 1 ? (items[0], 1) : (String(localized: "\(items.count) 个修饰键"), items.count)
    }

    static func glyph(_ m: LaptopModifier, _ p: LaptopPlatform) -> String {
        switch (m, p) {
        case (.shift, _): return "⇧"
        case (.ctrl, .mac): return "⌃"
        case (.ctrl, .windows): return "Ctrl"
        case (.alt, .mac): return "⌥"
        case (.alt, .windows): return "Alt"
        case (.cmd, _): return "⌘"
        case (.win, _): return "⊞"
        }
    }
}

/// 笔记本键盘的排版 (§4.9「排法」「能不能显示」)。纯函数。
/// 整块键盘一个节距 p = 单位键宽 + 6; 竖屏每行 14.5 单位, 横屏分体左半 7.25、右半 8 单位。
struct LaptopLayoutPlan: Equatable {
    enum Kind: Equatable { case portrait, split, tooSmall }
    var kind: Kind
    var unit: CGFloat
    var rowHeight: CGFloat
    /// 键盘块 (竖屏一块; 横屏左右两半)。
    var left: CGRect
    var right: CGRect?
    /// 横屏: 模式 + 语音竖排在左半外侧; 触控板 (连同左右键) 和掌托。
    var sideControls: CGRect?
    var trackpad: CGRect?
    var mouseRow: CGRect?
    var palm: CGRect?

    static let gap: CGFloat = 6
    static let minUnit: CGFloat = 28
    static let minRow: CGFloat = 40
    static let splitRowHeight: CGFloat = 50
    static let sideControlsWidth: CGFloat = 56
    static let mouseRowHeight: CGFloat = 56

    /// - Parameters:
    ///   - base: 同一窗口按网格模式算出的 DuoLayout (用它的键盘区、分界带、触控板区、底行)。
    ///   - swapped: 横屏调换 = 键盘不动, 触控板 (连同左右键) 和掌托左右互换; 竖屏照常调换 (base 已按调换偏好算好)。
    static func plan(base: DuoLayoutPlan, swapped: Bool) -> LaptopLayoutPlan {
        let g = gap
        func too() -> LaptopLayoutPlan { LaptopLayoutPlan(kind: .tooSmall, unit: 0, rowHeight: 0, left: .zero) }
        switch base.arrangement {
        case .stacked:
            // 竖屏 6 行 (含 F 键行), 占满键盘区; 下半部同普通双区 (触控板 + 左右键 + 胶囊)
            // 键要避开摄像头 (§3.8 第 4 条): 键盘块横向让开摄像头后再算单位键宽 (M3 审计 I2)
            guard let kb0 = base.keyboard, base.content == .dual else { return too() }
            let kb = DuoLayout.avoidCamera(kb0, base.camera, clearance: DuoPolicy.standard.cameraClearance)
            let p = (kb.width + g) / 14.5, unit = p - g
            let rowH = (kb.height - 5 * g) / 6
            guard unit >= minUnit, rowH >= minRow else { return too() }
            return LaptopLayoutPlan(kind: .portrait, unit: unit, rowHeight: rowH, left: kb, right: nil, sideControls: nil,
                                    trackpad: base.trackpad, mouseRow: base.mouseRow, palm: nil)
        case .sideBySide:
            // 横屏分体: 左半贴住分界带左沿, 右半从分界带右沿开始; 节距按右半宽度定 (右半 8 单位占满右侧区)
            // 分体只用于竖向内部分界 (§4.9 选表); 没有内部分界、宽 > 高的窗口要用半折键表 (M4), M3 里一律「空间不够」(审计 I8)
            guard base.divider != .none, let band = base.dividerBand else { return too() }
            let top = base.topBar.maxY + 12
            let x0 = base.topBar.minX, x1 = base.topBar.maxX
            // 节距取左右两半都放得下的较小值: 右半 8 单位不超过右侧区, 左半 7.25 单位不压到左侧「模式 + 语音」那一列
            // (画板 13 按显示状态栏画, 右半正好占满; 隐藏状态栏后右侧更宽, 由左半限制)
            let sideRight = x0 + sideControlsWidth + g
            let p = min((x1 - band.maxX + g) / 8, (band.minX - sideRight + g) / 7.25), unit = p - g
            let rightW = 8 * p - g
            let leftW = 7.25 * p - g
            let rowH = splitRowHeight
            let kbH = 5 * rowH + 4 * g
            let leftRect = CGRect(x: band.minX - leftW, y: top, width: leftW, height: kbH)
            let rightRect = CGRect(x: band.maxX, y: top, width: rightW, height: kbH)
            let side = CGRect(x: x0, y: top + 12, width: sideControlsWidth, height: 120)
            let below = kbH + top + 8
            let bottom = base.bottomRow.maxY
            let mouse = CGRect(x: 0, y: bottom - mouseRowHeight, width: 0, height: mouseRowHeight)
            // 能不能显示: 单位键宽 ≥ 28、行高 ≥ 40、左半外侧放得下模式 + 语音那一列; 下面还要放得下触控板
            guard unit >= minUnit, leftRect.minX - g >= side.maxX, mouse.minY - 8 - below >= 80 else { return too() }
            let tpX = swapped ? (x0, band.minX) : (band.maxX, x1)
            let palmX = swapped ? (band.maxX, x1) : (x0, band.minX)
            let tp = CGRect(x: tpX.0, y: below, width: tpX.1 - tpX.0, height: mouse.minY - 8 - below)
            let mr = DuoLayout.avoidCamera(CGRect(x: tpX.0, y: mouse.minY, width: tpX.1 - tpX.0, height: mouseRowHeight),
                                           base.camera, clearance: DuoPolicy.standard.cameraClearance)
            // 键盘两半、左侧控件列碰到摄像头就回退 (不缩键)
            let grownCams = base.camera.map { $0.insetBy(dx: -DuoPolicy.standard.cameraClearance, dy: -DuoPolicy.standard.cameraClearance) }
            guard !grownCams.contains(where: { $0.intersects(leftRect) || $0.intersects(rightRect) || $0.intersects(side) }),
                  mr.width >= 2 * 44 + g else { return too() }
            let palm = CGRect(x: palmX.0, y: below, width: palmX.1 - palmX.0, height: bottom - below)
            return LaptopLayoutPlan(kind: .split, unit: unit, rowHeight: rowH, left: leftRect, right: rightRect, sideControls: side,
                                    trackpad: tp, mouseRow: mr, palm: palm)
        }
    }

    /// 语音面板 + 系统键盘时, 按**实际的笔记本排法**定面板和触控板 (M3 审计 I1):
    /// 横屏分体时笔记本键盘整块让给面板, 面板放在掌托那一侧, 触控板留在它实际所在的一侧 (调换后也对)。
    static func voiceBase(base: DuoLayoutPlan, laptop: LaptopLayoutPlan) -> DuoLayoutPlan {
        guard laptop.kind == .split, let tp = laptop.trackpad, let palm = laptop.palm, let kb = base.keyboard, let btp = base.trackpad else { return base }
        var b = base
        b.keyboard = CGRect(x: palm.minX, y: kb.minY, width: palm.width, height: kb.height)
        b.trackpad = CGRect(x: tp.minX, y: btp.minY, width: tp.width, height: btp.height)
        b.dock = CGRect(x: palm.minX, y: base.dock.minY, width: min(base.dock.width, palm.width), height: base.dock.height)
        return b
    }

    /// 一行键的 x 位置 (同一节距: 宽 w 单位的键 = w × p − 6)。
    static func keyFrames(_ row: [LaptopKey], in r: CGRect, rowIndex: Int, unit: CGFloat, rowH: CGFloat) -> [CGRect] {
        let p = unit + gap
        var x = r.minX
        let y = r.minY + CGFloat(rowIndex) * (rowH + gap)
        return row.map { k in
            let w = CGFloat(k.width) * p - gap
            defer { x += w + gap }
            return CGRect(x: x, y: y, width: w, height: rowH)
        }
    }
}
