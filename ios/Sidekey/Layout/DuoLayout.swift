import CoreGraphics

// 层 3「纯计算」(§7): 稳定的观测快照 + 当前页 + 调换偏好 + 单区选择 + 策略参数 → 各区 frame。
// 纯函数: 不连网、不写存档、不管计时器。所有坐标都是窗口坐标 (原点 = 窗口左上角)。
// 只用于内屏 (screen == .inner); 手机屏仍走 M1 的 PhoneLandscape / 竖屏网格。

/// 布局的策略参数 (尺寸都来自 UI 稿 ui-v1 和需求 §3.3、§3.5; 只在这里定义一次, 不在视图里写死)。
struct DuoPolicy: Equatable {
    /// 折痕间距: 内部分界非激活 / 没有内部分界时, 分界线每侧留多少 (§3.3, 2026-10-26 用户确认每侧 24)。
    var creaseGap: CGFloat = 24
    /// 内部分界激活 (书本 / 半折) 时, 在系统返回的 frame 之外**再**留多少。§3.3 说边距已含在 frame 里、不另外加 → 0。
    /// (UI 稿画板 12 的书本姿势在 40 pt frame 外又画了 12, 和需求不一致, 待需求会话确认; 做成参数, 改这里即可。)
    var activeCreaseExtra: CGFloat = 0
    /// 左右边距: 贴着屏幕裸边 20, 贴着安全区 / 避让区 12; 窄窗口一律 12 (UI 稿 03 / 04 / 09)。
    var bareEdgeMargin: CGFloat = 20
    var insetEdgeMargin: CGFloat = 12
    var topMargin: CGFloat = 12
    var bottomMargin: CGFloat = 12
    var topBarHeight: CGFloat = 44
    var topBarGap: CGFloat = 12
    /// 底行 (语音 + 模式胶囊, 竖向时还有鼠标键): 宽窗口 64 高、胶囊 200 宽; 窄窗口 56 高、胶囊 132 宽。
    var bottomRowHeight: CGFloat = 64
    var narrowBottomRowHeight: CGFloat = 56
    var dockWidth: CGFloat = 200
    var narrowDockWidth: CGFloat = 132
    /// 单独的鼠标键行 (调换后贴在触控板下沿 / 单区触控板下方)。
    var mouseRowHeight: CGFloat = 56
    /// 分页行 (分页条 + 子页圆点) 和它下面的间距。
    var pagerRowHeight: CGFloat = 44
    var gap: CGFloat = 8
    /// 网格 (§3.5): 每格宽 ≥ 20, 列距 8, 行高 40, 行距 8; 双区时键盘至少 2 行。
    var minCellWidth: CGFloat = PhoneLandscape.minCellWidth
    var columnGap: CGFloat = PhoneLandscape.columnGap
    var minDualKeyRows: Int = 2
    /// 双区触控板最小 200 × 160; 单区触控板本身最小 160 × 80 (§3.5 第 5 条, 鼠标键行另算)。
    var dualTrackpadMin = CGSize(width: 200, height: 160)
    var singleTrackpadMin = CGSize(width: 160, height: 80)
    /// 内容宽 < 480 是窄窗口 (§4.6)。
    var narrowWidth: CGFloat = 480
    /// 按键、控件离摄像头区至少多远 (§3.8 第 4 条: 只有触控板可以延伸到摄像头下面)。
    var cameraClearance: CGFloat = 8
    /// 大屏键位一行最高多少 (行少、区大时不把键拉得过高; UI 稿 README「行高上限候选 88 pt」, 待真机定)。
    var maxKeyRowHeight: CGFloat = 88

    static let standard = DuoPolicy()

    func minGridWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * minCellWidth + CGFloat(max(0, columns - 1)) * columnGap
    }
    func gridHeight(rows: Int) -> CGFloat {
        rows <= 0 ? 0 : CGFloat(rows) * SubpageSplitter.minRowHeight + CGFloat(rows - 1) * SubpageSplitter.rowGap
    }
}

/// 当前页里布局要知道的东西。
struct DuoPageInfo: Equatable {
    var columns: Int
    var rowCount: Int
    var keys: [KeyCap]
    var pageCount: Int
}

enum DuoArrangement: String, Equatable { case stacked, sideBySide }       // 上下分区 / 左右分区
enum DuoPosture: String, Equatable { case flat, book, laptop }            // 全开 / 书本 (竖向折痕激活) / 笔记本 (横向折痕激活)

/// 分界的来源 (§3.3 第一步)。
enum DuoDividerKind: String, Equatable {
    case activeCrease          // 内部分界, 激活: 按系统 frame 避让
    case inactiveCrease        // 内部分界, 非激活: 中心线每侧 24
    case none                  // 没有内部分界 (窗口完全在折痕一侧): 内容区中线每侧 24
}

enum DuoContent: Equatable {
    case dual
    case single(SingleZone)
    /// 键盘单区也放不下这一页的列数 (§3.5 第 4 条): 「窗口太窄」+「切到触控板」。neededWidth = 按键区要多宽。
    case tooNarrow(neededWidth: CGFloat)
    /// 触控板单区放不下 (§3.5 第 5 条): 「窗口太小」。needed = 含鼠标键的输入区要多大。
    case tooSmall(needed: CGSize)
}

struct DuoLayoutPlan: Equatable {
    var arrangement: DuoArrangement
    var posture: DuoPosture
    var divider: DuoDividerKind
    var content: DuoContent
    var isNarrow: Bool
    /// 扣掉安全区、边缘避让区、激活的遮挡区之后的可用区域。
    var usable: CGRect
    /// 分界线处不放东西的带子 (折痕 + 间距)。
    var dividerBand: CGRect?
    var topBar: CGRect
    /// 顶栏里要避开的区域 (摄像头, §3.8 第 4 条)。
    var topBarAvoid: [CGRect]
    /// 底行 (竖向 / 窄窗口: 语音 + 模式胶囊, 未调换时还有鼠标键; 横向: 键盘一侧放胶囊, 触控板一侧放鼠标键)。
    var bottomRow: CGRect
    var dock: CGRect
    /// 键盘区整块 (含分页行); 分页行; 网格。
    var keyboard: CGRect?
    var pagerRow: CGRect?
    var grid: CGRect?
    var trackpad: CGRect?
    var mouseRow: CGRect?
    /// 边缘避让区 (被裁掉的折痕) 和摄像头区, 预览 / 调试用。
    var edgeAvoid: [CGRect]
    var camera: [CGRect]
    /// 网格能放下的行数 N (行高 40); 子页按它切。
    var rowsFit: Int
    var subpages: [Subpage]
    /// 调换键只在双区出现; 笔记本姿势不显示 (§4.4)。
    var swapAvailable: Bool

    /// 「键盘 / 触控板」切换在单区、以及单区放不下 (窗口太窄 / 太小) 时都要能点到 (§3.5)。
    var showsZoneToggle: Bool {
        switch content { case .dual: return false; case .single, .tooNarrow, .tooSmall: return true }
    }
}

enum DuoLayout {

    // MARK: - 第一步: 折痕分类 (§3.3)

    struct Classified: Equatable {
        var internalDivision: DuoRegion?
        var edgeAvoid: [CGRect]
        var activeOcclusion: [CGRect]
        var camera: [CGRect]
    }

    /// 看折痕**短的那个方向**: 在这个方向上完整落在窗口里、两侧都有内容空间 → 内部分界;
    /// 被窗口截断或贴边 (≤ 1 pt) → 边缘避让。长的方向超出窗口不影响分类 (v1.7)。
    static func classify(_ o: DuoObservation) -> Classified {
        var c = Classified(internalDivision: nil, edgeAvoid: [], activeOcclusion: [], camera: [])
        let w = o.windowRect
        for r in o.regions {
            switch r.kind {
            case .division:
                let vertical = r.frame.height >= r.frame.width
                let lo = vertical ? r.frame.minX : r.frame.minY, hi = vertical ? r.frame.maxX : r.frame.maxY
                let edge = vertical ? w.width : w.height
                if lo > 1, hi < edge - 1, c.internalDivision == nil { c.internalDivision = r }
                else { c.edgeAvoid.append(r.frame.intersection(w)) }
            case .occlusion:
                // 激活的遮挡区 (状态栏角) 照常避让; 非激活的是内屏摄像头 (§3.8 第 4 条): 不扣可用区, 只让按键 / 控件避开
                if r.isActive { c.activeOcclusion.append(r.frame.intersection(w)) } else { c.camera.append(r.frame.intersection(w)) }
            }
        }
        return c
    }

    static func posture(_ o: DuoObservation, _ c: Classified) -> DuoPosture {
        guard o.hinge == .partiallyOpen, let d = c.internalDivision, d.isActive else { return .flat }
        return d.frame.height >= d.frame.width ? .book : .laptop
    }

    // MARK: - 第二步: 扣空间

    /// 从可用区里扣掉一块: 只能整边收缩, 选扣完剩下面积最大的那一边 (边缘避让条贴哪边就收哪边)。
    static func deduct(_ r: CGRect, from u: CGRect) -> (CGRect, edge: Edge?) {
        let i = r.intersection(u)
        guard !i.isNull, i.width > 0, i.height > 0 else { return (u, nil) }
        let options: [(CGRect, Edge)] = [
            (CGRect(x: i.maxX, y: u.minY, width: u.maxX - i.maxX, height: u.height), .left),
            (CGRect(x: u.minX, y: u.minY, width: i.minX - u.minX, height: u.height), .right),
            (CGRect(x: u.minX, y: i.maxY, width: u.width, height: u.maxY - i.maxY), .top),
            (CGRect(x: u.minX, y: u.minY, width: u.width, height: i.minY - u.minY), .bottom),
        ]
        let best = options.max { $0.0.width * $0.0.height < $1.0.width * $1.0.height }!
        return (best.0, best.1)
    }
    enum Edge { case left, right, top, bottom }

    /// 让一块放按键 / 控件的矩形避开摄像头区: 横向收缩 (选损失小的一边), 留 cameraClearance。
    static func avoidCamera(_ r: CGRect, _ cams: [CGRect], clearance: CGFloat) -> CGRect {
        var out = r
        for cam in cams {
            let grown = cam.insetBy(dx: -clearance, dy: -clearance)
            guard out.intersects(grown) else { continue }
            let keepLeft = CGRect(x: out.minX, y: out.minY, width: max(0, grown.minX - out.minX), height: out.height)
            let keepRight = CGRect(x: grown.maxX, y: out.minY, width: max(0, out.maxX - grown.maxX), height: out.height)
            out = keepLeft.width >= keepRight.width ? keepLeft : keepRight
        }
        return out
    }

    /// 沿所在行左右平移, 让开摄像头 (不缩小); 行内找不到位置返回 nil。用于单区的胶囊 (M3 审计 R-I2)。
    static func shiftAvoidingCamera(_ r: CGRect, within row: CGRect, _ cams: [CGRect], clearance: CGFloat) -> CGRect? {
        let grown = cams.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        func hits(_ x: CGRect) -> Bool { grown.contains { x.intersects($0) } }
        guard hits(r) else { return r }
        let candidates = grown.flatMap { g in [r.offsetBy(dx: g.maxX - r.minX, dy: 0), r.offsetBy(dx: g.minX - r.maxX, dy: 0)] }
        return candidates
            .filter { $0.minX >= row.minX - 0.5 && $0.maxX <= row.maxX + 0.5 && !hits($0) }
            .min { abs($0.minX - r.minX) < abs($1.minX - r.minX) }
    }

    // MARK: - 主函数

    static func plan(_ raw: DuoObservation, page: DuoPageInfo, swapped: Bool,
                     singleChoice: SingleZone = .keys, forceSingle: Bool = false, policy p: DuoPolicy = .standard) -> DuoLayoutPlan {
        let o = raw.normalized()
        let c = classify(o)
        let posture = posture(o, c)

        // 1. 原始窗口矩形一次扣掉安全区、边缘避让区、激活的遮挡区 (重叠部分不重复扣)
        var usable = CGRect(x: o.safe.left, y: o.safe.top,
                            width: max(0, o.window.width - o.safe.left - o.safe.right),
                            height: max(0, o.window.height - o.safe.top - o.safe.bottom))
        var insetEdges: Set<Edge> = []
        if o.safe.left > 0 { insetEdges.insert(.left) }
        if o.safe.right > 0 { insetEdges.insert(.right) }
        for r in c.edgeAvoid + c.activeOcclusion {
            let (u, e) = deduct(r, from: usable)
            usable = u
            if let e { insetEdges.insert(e) }
        }

        // 2. 外围控件: 顶栏、左右边距、底行
        let wideL = insetEdges.contains(.left) ? p.insetEdgeMargin : p.bareEdgeMargin
        let wideR = insetEdges.contains(.right) ? p.insetEdgeMargin : p.bareEdgeMargin
        let isNarrow = usable.width - wideL - wideR < p.narrowWidth
        let ml = isNarrow ? p.insetEdgeMargin : wideL, mr = isNarrow ? p.insetEdgeMargin : wideR
        let x0 = usable.minX + ml, x1 = usable.maxX - mr
        let topBar = CGRect(x: x0, y: usable.minY + p.topMargin, width: max(0, x1 - x0), height: p.topBarHeight)
        let top = topBar.maxY + p.topBarGap                                    // 内容区上沿 (UI 稿 K0)
        let rowH = isNarrow ? p.narrowBottomRowHeight : p.bottomRowHeight
        let dockW = isNarrow ? p.narrowDockWidth : p.dockWidth
        let bottomRow = CGRect(x: x0, y: usable.maxY - p.bottomMargin - rowH, width: max(0, x1 - x0), height: rowH)
        let bot = bottomRow.minY - p.gap                                      // 两区下沿
        let content = CGRect(x: x0, y: top, width: max(0, x1 - x0), height: max(0, bot - top))

        // 3. 分界线
        let arrangement: DuoArrangement
        let dividerKind: DuoDividerKind
        var band: (lo: CGFloat, hi: CGFloat)?            // 分界带在分区方向上的范围
        if let d = c.internalDivision {
            let vertical = d.frame.height >= d.frame.width
            arrangement = vertical ? .sideBySide : .stacked
            if d.isActive {
                dividerKind = .activeCrease
                let lo = vertical ? d.frame.minX : d.frame.minY, hi = vertical ? d.frame.maxX : d.frame.maxY
                band = (lo - p.activeCreaseExtra, hi + p.activeCreaseExtra)
            } else {
                dividerKind = .inactiveCrease
                let mid = vertical ? d.frame.midX : d.frame.midY
                band = (mid - p.creaseGap, mid + p.creaseGap)
            }
        } else {
            dividerKind = .none
            arrangement = o.window.height >= o.window.width ? .stacked : .sideBySide
        }

        var plan = DuoLayoutPlan(arrangement: arrangement, posture: posture, divider: dividerKind, content: .dual,
                                 isNarrow: isNarrow, usable: usable, dividerBand: nil, topBar: topBar,
                                 topBarAvoid: c.camera.filter { $0.intersects(topBar) }, bottomRow: bottomRow,
                                 dock: .zero, keyboard: nil, pagerRow: nil, grid: nil, trackpad: nil, mouseRow: nil,
                                 edgeAvoid: c.edgeAvoid, camera: c.camera, rowsFit: 0, subpages: [], swapAvailable: false)

        // 4. 双区: 先按「不需要分页行」排; 只有 1 页但切出了子页时, 加上分页行再排一次
        let needsPagerForPages = page.pageCount > 1
        var dual = dualZones(arrangement: arrangement, band: band, content: content, bottomRow: bottomRow,
                             dockW: dockW, swapped: swapped, pager: needsPagerForPages, p: p)
        dual.avoid(c.camera, p)
        var n = SubpageSplitter.rowsThatFit(height: dual.grid.height)
        var subs = SubpageSplitter.split(keys: page.keys, totalRows: page.rowCount, maxRows: n)
        if !needsPagerForPages, subs.count > 1 {
            dual = dualZones(arrangement: arrangement, band: band, content: content, bottomRow: bottomRow,
                             dockW: dockW, swapped: swapped, pager: true, p: p)
            dual.avoid(c.camera, p)
            n = SubpageSplitter.rowsThatFit(height: dual.grid.height)
            subs = SubpageSplitter.split(keys: page.keys, totalRows: page.rowCount, maxRows: n)
        }
        plan.dividerBand = dual.bandRect

        // 5. 双区条件 (§3.5): 每格 ≥ 20、键盘至少 2 行、触控板 ≥ 200 × 160
        let fitsDual = dual.grid.width >= p.minGridWidth(columns: page.columns)
            && n >= min(p.minDualKeyRows, max(1, page.rowCount))
            && dual.trackpad.width >= p.dualTrackpadMin.width && dual.trackpad.height >= p.dualTrackpadMin.height
        if fitsDual, !forceSingle {
            plan.content = .dual
            plan.keyboard = dual.keyboard; plan.pagerRow = dual.pager; plan.grid = dual.grid
            plan.trackpad = dual.trackpad; plan.mouseRow = dual.mouse; plan.dock = dual.dock
            plan.rowsFit = n; plan.subpages = subs
            plan.swapAvailable = posture != .laptop
            return plan
        }

        // 6. 单区 (§3.5 第 3–5 条): 不跨任何内部分界; 选能放下、面积较大的一侧
        return single(plan: plan, choice: singleChoice, arrangement: arrangement, band: band, content: content,
                      bottomRow: bottomRow, dockW: dockW, swapped: swapped, page: page, camera: c.camera, p: p)
    }

    // MARK: - 双区排法

    struct Zones {
        var keyboard: CGRect, pager: CGRect?, grid: CGRect, trackpad: CGRect, mouse: CGRect, dock: CGRect
        var bandRect: CGRect?

        /// 按键、分页行、鼠标键、胶囊都避开摄像头; 触控板可以延伸到它下面 (§3.8 第 4 条)。
        mutating func avoid(_ cams: [CGRect], _ p: DuoPolicy) {
            guard !cams.isEmpty else { return }
            grid = DuoLayout.avoidCamera(grid, cams, clearance: p.cameraClearance)
            if let pg = pager { pager = DuoLayout.avoidCamera(pg, cams, clearance: p.cameraClearance) }
            mouse = DuoLayout.avoidCamera(mouse, cams, clearance: p.cameraClearance)
            dock = DuoLayout.avoidCamera(dock, cams, clearance: p.cameraClearance)
        }
    }

    /// 底行里鼠标键和胶囊的分法: 胶囊靠右 (竖向) 或靠键盘一侧 (横向), 鼠标键占剩下的部分。
    private static func splitRow(_ row: CGRect, dockW: CGFloat, dockOnRight: Bool, gap: CGFloat) -> (mouse: CGRect, dock: CGRect) {
        let dw = min(dockW, row.width)
        let dock = CGRect(x: dockOnRight ? row.maxX - dw : row.minX, y: row.minY, width: dw, height: row.height)
        let mw = max(0, row.width - dw - gap)
        let mouse = CGRect(x: dockOnRight ? row.minX : row.maxX - mw, y: row.minY, width: mw, height: row.height)
        return (mouse, dock)
    }

    private static func keyboardParts(_ kb: CGRect, pager: Bool, p: DuoPolicy) -> (CGRect?, CGRect) {
        guard pager else { return (nil, kb) }
        let pr = CGRect(x: kb.minX, y: kb.minY, width: kb.width, height: p.pagerRowHeight)
        let gy = pr.maxY + p.gap
        return (pr, CGRect(x: kb.minX, y: gy, width: kb.width, height: max(0, kb.maxY - gy)))
    }

    static func dualZones(arrangement: DuoArrangement, band: (lo: CGFloat, hi: CGFloat)?, content: CGRect,
                          bottomRow: CGRect, dockW: CGFloat, swapped: Bool, pager: Bool, p: DuoPolicy) -> Zones {
        let hdr = pager ? p.pagerRowHeight + p.gap : 0
        switch arrangement {
        case .stacked:
            var kb: CGRect, tp: CGRect, mouse: CGRect, dock: CGRect, bandRect: CGRect
            if let band {
                // 有内部分界: 分界线就是折痕, 两区不要求等高 (§3.3)
                let upper = CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, band.lo - content.minY))
                let lower = CGRect(x: content.minX, y: band.hi, width: content.width, height: max(0, content.maxY - band.hi))
                bandRect = CGRect(x: content.minX, y: band.lo, width: content.width, height: band.hi - band.lo)
                if !swapped {
                    kb = upper; tp = lower
                    (mouse, dock) = splitRow(bottomRow, dockW: dockW, dockOnRight: true, gap: p.gap)
                } else {
                    // 调换后: 鼠标键行跟着触控板到上面, 紧贴触控板下沿; 底行只剩胶囊 (竖向时不随调换移动)
                    mouse = CGRect(x: upper.minX, y: upper.maxY - p.mouseRowHeight, width: upper.width, height: p.mouseRowHeight)
                    tp = CGRect(x: upper.minX, y: upper.minY, width: upper.width, height: max(0, mouse.minY - p.gap - upper.minY))
                    kb = lower
                    dock = splitRow(bottomRow, dockW: dockW, dockOnRight: true, gap: p.gap).dock
                }
            } else {
                // 没有内部分界 (§3.3 窄窗口的排法): 附属控件和外围控件一起先扣, 剩下的两区平分
                if !swapped {
                    let ky = content.minY + hdr
                    let mid = (ky + content.maxY) / 2
                    kb = CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, mid - p.creaseGap - content.minY))
                    tp = CGRect(x: content.minX, y: mid + p.creaseGap, width: content.width, height: max(0, content.maxY - mid - p.creaseGap))
                    bandRect = CGRect(x: content.minX, y: mid - p.creaseGap, width: content.width, height: 2 * p.creaseGap)
                    (mouse, dock) = splitRow(bottomRow, dockW: dockW, dockOnRight: true, gap: p.gap)
                } else {
                    let mouseBlock = p.mouseRowHeight + p.gap
                    let zone = max(0, (content.height - mouseBlock - hdr - 2 * p.creaseGap) / 2)
                    tp = CGRect(x: content.minX, y: content.minY, width: content.width, height: zone)
                    mouse = CGRect(x: content.minX, y: tp.maxY + p.gap, width: content.width, height: p.mouseRowHeight)
                    let kbTop = tp.maxY + mouseBlock + 2 * p.creaseGap
                    kb = CGRect(x: content.minX, y: kbTop, width: content.width, height: max(0, content.maxY - kbTop))
                    bandRect = CGRect(x: content.minX, y: mouse.maxY, width: content.width, height: 2 * p.creaseGap)
                    dock = splitRow(bottomRow, dockW: dockW, dockOnRight: true, gap: p.gap).dock
                }
            }
            let (pr, grid) = keyboardParts(kb, pager: pager, p: p)
            return Zones(keyboard: kb, pager: pr, grid: grid, trackpad: tp, mouse: mouse, dock: dock, bandRect: bandRect)

        case .sideBySide:
            // 左右分区: 两区从内容区上沿到底行上方; 底行在键盘一侧放胶囊、触控板一侧放鼠标键 (§4.3)
            let lo: CGFloat, hi: CGFloat
            if let band { lo = band.lo; hi = band.hi } else { let mid = content.midX; lo = mid - p.creaseGap; hi = mid + p.creaseGap }
            let left = CGRect(x: content.minX, y: content.minY, width: max(0, lo - content.minX), height: content.height)
            let right = CGRect(x: hi, y: content.minY, width: max(0, content.maxX - hi), height: content.height)
            let kb = swapped ? right : left, tp = swapped ? left : right
            let dock = CGRect(x: kb.minX, y: bottomRow.minY, width: min(dockW, kb.width), height: bottomRow.height)
            let mouse = CGRect(x: tp.minX, y: bottomRow.minY, width: tp.width, height: bottomRow.height)
            let (pr, grid) = keyboardParts(kb, pager: pager, p: p)
            let bandRect = CGRect(x: lo, y: content.minY, width: hi - lo, height: bottomRow.maxY - content.minY)
            return Zones(keyboard: kb, pager: pr, grid: grid, trackpad: tp, mouse: mouse, dock: dock, bandRect: bandRect)
        }
    }

    // MARK: - 单区

    private static func single(plan base: DuoLayoutPlan, choice: SingleZone, arrangement: DuoArrangement,
                               band: (lo: CGFloat, hi: CGFloat)?, content: CGRect, bottomRow: CGRect, dockW: CGFloat,
                               swapped: Bool, page: DuoPageInfo, camera: [CGRect], p: DuoPolicy) -> DuoLayoutPlan {
        var plan = base
        plan.swapAvailable = false
        plan.dividerBand = band.map { b in
            arrangement == .stacked ? CGRect(x: content.minX, y: b.lo, width: content.width, height: b.hi - b.lo)
                                    : CGRect(x: b.lo, y: content.minY, width: b.hi - b.lo, height: bottomRow.maxY - content.minY)
        }
        // 候选区域: 有内部分界时是分界两侧 (各自的「首选」由调换偏好决定), 没有时是整个内容区
        struct Side { var rect: CGRect; var isKeyboardSide: Bool }
        var sides: [Side] = []
        if let band {
            if arrangement == .stacked {
                sides = [Side(rect: CGRect(x: content.minX, y: content.minY, width: content.width, height: max(0, band.lo - content.minY)), isKeyboardSide: !swapped),
                         Side(rect: CGRect(x: content.minX, y: band.hi, width: content.width, height: max(0, content.maxY - band.hi)), isKeyboardSide: swapped)]
            } else {
                sides = [Side(rect: CGRect(x: content.minX, y: content.minY, width: max(0, band.lo - content.minX), height: content.height), isKeyboardSide: !swapped),
                         Side(rect: CGRect(x: band.hi, y: content.minY, width: max(0, content.maxX - band.hi), height: content.height), isKeyboardSide: swapped)]
            }
        } else {
            sides = [Side(rect: content, isKeyboardSide: true)]
        }

        let needsPager = page.pageCount > 1
        let mouseBlock = p.mouseRowHeight + p.gap
        func fits(_ r: CGRect) -> Bool {
            switch choice {
            case .keys:
                let g = avoidCamera(r, camera, clearance: p.cameraClearance)
                return g.width >= p.minGridWidth(columns: page.columns)
                    && g.height >= (needsPager ? p.pagerRowHeight + p.gap : 0) + p.gridHeight(rows: 1)
            case .trackpad:
                return r.width >= p.singleTrackpadMin.width && r.height >= p.singleTrackpadMin.height + mouseBlock
            }
        }
        // 能放下的一侧里选面积大的; 一样大时选这个区按调换偏好本来所在的一侧
        let wantKeyboardSide = choice == .keys
        let pick = sides.filter { fits($0.rect) }.max { a, b in
            let aa = a.rect.width * a.rect.height, bb = b.rect.width * b.rect.height
            if aa != bb { return aa < bb }
            return (a.isKeyboardSide == wantKeyboardSide ? 1 : 0) < (b.isKeyboardSide == wantKeyboardSide ? 1 : 0)
        }

        // 胶囊: 竖向固定在底行右侧; 横向在键盘本来所在一侧的底部
        let kbHome = sides.first { $0.isKeyboardSide }?.rect ?? content
        plan.dock = arrangement == .stacked
            ? splitRow(bottomRow, dockW: dockW, dockOnRight: true, gap: p.gap).dock
            : CGRect(x: kbHome.minX, y: bottomRow.minY, width: min(dockW, kbHome.width), height: bottomRow.height)
        // 胶囊让开摄像头 (R-I2): 先沿底行平移, 行内放不下才和双区一样缩
        let dockRow = arrangement == .stacked ? bottomRow : CGRect(x: kbHome.minX, y: bottomRow.minY, width: kbHome.width, height: bottomRow.height)
        plan.dock = shiftAvoidingCamera(plan.dock, within: dockRow, camera, clearance: p.cameraClearance)
            ?? avoidCamera(plan.dock, camera, clearance: p.cameraClearance)

        guard let area = pick?.rect else {
            switch choice {
            case .keys: plan.content = .tooNarrow(neededWidth: p.minGridWidth(columns: page.columns))
            case .trackpad: plan.content = .tooSmall(needed: CGSize(width: p.singleTrackpadMin.width, height: p.singleTrackpadMin.height + mouseBlock))
            }
            return plan
        }
        plan.content = .single(choice)
        switch choice {
        case .keys:
            let (pr0, g0) = keyboardParts(area, pager: needsPager, p: p)
            var grid = avoidCamera(g0, camera, clearance: p.cameraClearance)
            var pr = pr0.map { avoidCamera($0, camera, clearance: p.cameraClearance) }
            var n = SubpageSplitter.rowsThatFit(height: grid.height)
            var subs = SubpageSplitter.split(keys: page.keys, totalRows: page.rowCount, maxRows: n)
            if !needsPager, subs.count > 1 {
                let (pr1, g1) = keyboardParts(area, pager: true, p: p)
                grid = avoidCamera(g1, camera, clearance: p.cameraClearance)
                pr = pr1.map { avoidCamera($0, camera, clearance: p.cameraClearance) }
                n = SubpageSplitter.rowsThatFit(height: grid.height)
                subs = SubpageSplitter.split(keys: page.keys, totalRows: page.rowCount, maxRows: n)
            }
            // 扣完最终的分页行后至少还要放得下一行 40 pt 的键 (§3.5「N 至少为 1」, M3 审计 I4); 放不下就占位, 不切子页
            guard n >= 1 else {
                plan.content = .tooSmall(needed: CGSize(width: p.minGridWidth(columns: page.columns),
                                                        height: p.pagerRowHeight + p.gap + p.gridHeight(rows: 1)))
                return plan
            }
            plan.keyboard = area; plan.pagerRow = pr; plan.grid = grid; plan.rowsFit = n; plan.subpages = subs
        case .trackpad:
            // 显示触控板时左右键一起显示 (§3.5): 区域贴着底行时 (竖向、下侧) 鼠标键并进底行, 否则单独一行贴在触控板下沿
            // 鼠标键每个命中区至少 44 宽 (M3 审计 N-I5): 并进底行放不下就单独一行贴在触控板下沿; 再放不下就占位
            let minMouse = 2 * 44 + p.gap
            // 最终的鼠标键行统一处理 (R-I2): 先让开摄像头, 再让开胶囊; 之后才检查尺寸、交叠和分界, 不靠缩小命中区
            func finalMouse(_ r: CGRect) -> CGRect {
                avoidCamera(avoidCamera(r, camera, clearance: p.cameraClearance), [plan.dock], clearance: p.gap)
            }
            func accept(_ m: CGRect, trackpad tp: CGRect) -> Bool {
                guard m.width >= minMouse, m.height >= 44,
                      tp.width >= p.singleTrackpadMin.width, tp.height >= p.singleTrackpadMin.height,
                      !m.intersects(tp), !m.intersects(plan.dock), !tp.intersects(plan.dock) else { return false }
                if let d = plan.dividerBand, m.intersects(d) || tp.intersects(d) { return false }
                plan.mouseRow = m; plan.trackpad = tp
                return true
            }
            func ownRow() -> Bool {
                let m = finalMouse(CGRect(x: area.minX, y: area.maxY - p.mouseRowHeight, width: area.width, height: p.mouseRowHeight))
                let tp = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, area.maxY - p.mouseRowHeight - p.gap - area.minY))
                return accept(m, trackpad: tp)
            }
            var placed = false
            if arrangement == .stacked, area.maxY >= content.maxY - 0.5 {
                placed = accept(finalMouse(splitRow(bottomRow, dockW: dockW, dockOnRight: true, gap: p.gap).mouse), trackpad: area) || ownRow()
            } else if arrangement == .sideBySide {
                // 触控板落在键盘本来那一侧时, 鼠标键会碰到胶囊: finalMouse 让开
                placed = accept(finalMouse(CGRect(x: area.minX, y: bottomRow.minY, width: area.width, height: bottomRow.height)), trackpad: area) || ownRow()
            } else {
                placed = ownRow()
            }
            if !placed {
                plan.trackpad = nil; plan.mouseRow = nil
                plan.content = .tooSmall(needed: CGSize(width: max(p.singleTrackpadMin.width, minMouse), height: p.singleTrackpadMin.height + mouseBlock))
            }
        }
        return plan
    }
}

/// 窄窗口顶栏 (§4.6, 内容宽 W < 480): 状态圆钮 44 +「当前电脑」条 + 调换 44 (单区时换成 96 宽的「键盘 / 触控板」) + 设置 44, 间距 8。
/// 电脑条最窄 120。放不下时: 先去掉状态圆钮; 双区再把调换和设置收进一个「⋯」; 单区的切换始终留在顶栏; 再放不下就「窗口太窄」。
struct DuoTopBarPlan: Equatable {
    var showStatus: Bool
    /// true = 调换和设置收进「⋯」(只在双区)。
    var collapsedMenu: Bool
    var chipWidth: CGFloat
    /// 顶栏放不下最小的排法: 显示「窗口太窄」占位。
    var tooNarrow: Bool

    static let button: CGFloat = 44, toggle: CGFloat = 96, gap: CGFloat = 8, minChip: CGFloat = 120

    static func narrow(width w: CGFloat, single: Bool) -> DuoTopBarPlan {
        let right = single ? toggle + gap + button : button + gap + button      // 右段: 切换 + 设置 / 调换 + 设置
        let withStatus = w - (button + gap) - gap - right                       // 双区 W − 156, 单区 W − 208
        if withStatus >= minChip { return DuoTopBarPlan(showStatus: true, collapsedMenu: false, chipWidth: withStatus, tooNarrow: false) }
        let noStatus = w - gap - right                                          // 双区 W − 104, 单区 W − 156
        if noStatus >= minChip { return DuoTopBarPlan(showStatus: false, collapsedMenu: false, chipWidth: noStatus, tooNarrow: false) }
        if !single {
            let menu = w - gap - button                                         // 双区: 电脑条 + 「⋯」
            if menu >= minChip { return DuoTopBarPlan(showStatus: false, collapsedMenu: true, chipWidth: menu, tooNarrow: false) }
        }
        return DuoTopBarPlan(showStatus: false, collapsedMenu: !single, chipWidth: minChip, tooNarrow: true)
    }
}

/// 语音面板 + 系统键盘 (§4.8「语音面板和系统键盘」, T-VO-1)。纯函数。
/// 计算顺序 (v1.7): 先算系统键盘和本窗口实际重叠的部分 → 再定面板停在哪 → 最后给触控板分三档。
/// 三档只改触控板, 不压缩面板里的必需控件; 面板本身放不下时改成盖住整个窗口的语音页 (modal)。
struct DuoVoiceKeyboardPlan: Equatable {
    enum Tier: String, Equatable { case full, small, hidden }
    /// true = 紧凑条放不下, 改成盖住整个窗口的语音页。
    var modal: Bool
    /// 紧凑条 (窗口坐标); modal 时 nil。
    var panel: CGRect?
    var tier: Tier
    var trackpad: CGRect?
    /// 完整档: 下方一行两个; 小档: 右侧竖排两个 (宽 72)。
    var mouseButtons: [CGRect]
    /// 系统键盘以上可见区域的下沿 (窗口坐标)。
    var visibleBottom: CGFloat

    static let panelHeight: CGFloat = 136
    /// 紧凑条最窄要多宽 (必需控件 + 文字框 + 发送 88), 初定值, Q19 实测后再调。
    static let minPanelWidth: CGFloat = 280
    static let smallSideWidth: CGFloat = 72
    static let smallMinHeight: CGFloat = 96

    /// - Parameters:
    ///   - base: 键盘没弹起时的布局 (DuoLayout.plan 的结果; 容器尺寸里**没有**扣键盘, 避免减两次)。
    ///   - keyboard: 系统键盘在窗口坐标里的 frame (可能比窗口宽, 例如 Split View 里整屏宽); 和窗口取交集才算重叠。
    /// - Returns: nil = 键盘没挡住输入区 (高 0 或在窗口外), 按 base 原样排。
    static func plan(base: DuoLayoutPlan, keyboard: CGRect, window: CGSize, policy p: DuoPolicy = .standard) -> DuoVoiceKeyboardPlan? {
        let overlap = keyboard.intersection(CGRect(origin: .zero, size: window))
        guard !overlap.isNull, overlap.height > 0, overlap.width > 0 else { return nil }      // 收起后是高 0 的一条 (§3.8 第 2 条)
        let contentTop = base.topBar.maxY + p.topBarGap
        let visibleBottom = min(overlap.minY - p.gap, base.bottomRow.maxY)
        guard overlap.minY < base.bottomRow.maxY else { return nil }                              // 键盘没碰到输入区
        let x0 = base.topBar.minX, x1 = base.topBar.maxX
        var panel: CGRect
        var area: CGRect                                                                          // 触控板可用区域
        switch base.arrangement {
        case .sideBySide:
            // 左右分区: 面板停在键盘那一侧, 贴在系统键盘上方; 触控板那一侧按可见高度重排
            let kb = base.keyboard ?? base.grid ?? CGRect(x: x0, y: contentTop, width: (x1 - x0) / 2, height: 0)
            panel = CGRect(x: kb.minX, y: visibleBottom - panelHeight, width: kb.width, height: panelHeight)
            let tp = base.trackpad ?? base.mouseRow ?? CGRect(x: kb.maxX, y: contentTop, width: x1 - kb.maxX, height: 0)
            area = CGRect(x: tp.minX, y: contentTop, width: tp.width, height: max(0, visibleBottom - contentTop))
        case .stacked:
            // 上下分区: 面板停在键盘那一端 (未调换 = 上端, 调换后 = 下端), 剩下的可见区域给触控板, 不跨内部分界 (§5.3)
            let keyboardOnTop = (base.keyboard?.minY ?? contentTop) <= (base.trackpad?.minY ?? .greatestFiniteMagnitude)
            let visible = CGRect(x: x0, y: contentTop, width: x1 - x0, height: max(0, visibleBottom - contentTop))
            panel = keyboardOnTop
                ? CGRect(x: x0, y: visible.minY, width: visible.width, height: panelHeight)
                : CGRect(x: x0, y: visible.maxY - panelHeight, width: visible.width, height: panelHeight)
            let rest = keyboardOnTop
                ? CGRect(x: x0, y: panel.maxY + p.gap, width: visible.width, height: max(0, visible.maxY - panel.maxY - p.gap))
                : CGRect(x: x0, y: visible.minY, width: visible.width, height: max(0, panel.minY - p.gap - visible.minY))
            // 只有真的折痕 (内部分界) 才挡触控板; 没有内部分界时那条带子只是窗口中线, 不用避开
            area = tallestSlice(rest, avoiding: base.divider == .none ? nil : base.dividerBand)
        }
        // 面板放不下必需控件: 盖住整个窗口的语音页
        if panel.minY < contentTop - 0.5 || panel.maxY > visibleBottom + 0.5 || panel.width < minPanelWidth {
            return DuoVoiceKeyboardPlan(modal: true, panel: nil, tier: .hidden, trackpad: nil, mouseButtons: [], visibleBottom: visibleBottom)
        }
        // 三档 (按触控板本体的净尺寸)
        let mouseBlock = p.mouseRowHeight + p.gap
        if area.height - mouseBlock >= p.dualTrackpadMin.height, area.width >= p.dualTrackpadMin.width {
            let tp = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - mouseBlock)
            let bw = (area.width - p.gap) / 2, by = tp.maxY + p.gap
            return DuoVoiceKeyboardPlan(modal: false, panel: panel, tier: .full, trackpad: tp,
                                        mouseButtons: [CGRect(x: area.minX, y: by, width: bw, height: p.mouseRowHeight),
                                                       CGRect(x: area.minX + bw + p.gap, y: by, width: bw, height: p.mouseRowHeight)],
                                        visibleBottom: visibleBottom)
        }
        if area.width - smallSideWidth - p.gap >= p.dualTrackpadMin.width, area.height >= smallMinHeight {
            let tp = CGRect(x: area.minX, y: area.minY, width: area.width - smallSideWidth - p.gap, height: area.height)
            let bh = (area.height - p.gap) / 2, bx = tp.maxX + p.gap
            return DuoVoiceKeyboardPlan(modal: false, panel: panel, tier: .small, trackpad: tp,
                                        mouseButtons: [CGRect(x: bx, y: area.minY, width: smallSideWidth, height: bh),
                                                       CGRect(x: bx, y: area.minY + bh + p.gap, width: smallSideWidth, height: bh)],
                                        visibleBottom: visibleBottom)
        }
        return DuoVoiceKeyboardPlan(modal: false, panel: panel, tier: .hidden, trackpad: nil, mouseButtons: [], visibleBottom: visibleBottom)
    }

    /// 一块区域被分界带切开时, 取较高的那一段 (触控板不跨折痕)。
    static func tallestSlice(_ r: CGRect, avoiding band: CGRect?) -> CGRect {
        guard let band, r.height > 0, band.minY < r.maxY, band.maxY > r.minY, band.width >= band.height else { return r }
        let upper = CGRect(x: r.minX, y: r.minY, width: r.width, height: max(0, band.minY - r.minY))
        let lower = CGRect(x: r.minX, y: band.maxY, width: r.width, height: max(0, r.maxY - band.maxY))
        return upper.height >= lower.height ? upper : lower
    }
}
