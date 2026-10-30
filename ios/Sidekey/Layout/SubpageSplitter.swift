import CoreGraphics

/// 子页 (§3.6): 空间不够时把一页按行切成几个「子页」, 只在显示时存在, 不进存档、不改 `KeyLayer`。
struct Subpage: Equatable {
    var rows: Range<Int>
    /// 超高子页: 里面有比 N 行更高的键 (或一组互相卡住的跨行键), 要压缩行高让整段「刚好放下」, 压到 28 pt 还放不下就在子页内滚动。
    var isTall: Bool
}

enum SubpageSplitter {
    /// 键盘行高的下限 (§3.5) 与超高子页的压缩下限 (§3.6)。
    static let minRowHeight: CGFloat = 40
    static let tallMinRowHeight: CGFloat = 28
    static let rowGap: CGFloat = 8

    /// 切分算法 (保证能切完): 每一步至少前进一行; 切线不会穿过任何按键; 超高键单独成一个标记过的子页。
    /// - Parameters:
    ///   - keys: 这一页的键 (用 row / rowSpan)
    ///   - totalRows: 这一页的总行数
    ///   - maxRows: 当前能放下的行数 N (至少按 1 处理)
    static func split(keys: [KeyCap], totalRows: Int, maxRows: Int) -> [Subpage] {
        let n = max(1, maxRows)
        guard totalRows > 0 else { return [] }
        var result: [Subpage] = []
        var start = 0
        while start < totalRows {
            var end = min(start + n, totalRows)
            // 有键跨过 end (row < end < row + rowSpan) → 把 end 提前到这些键里最小的 row, 直到没有键跨过
            while let cross = crossing(keys, at: end)?.map(\.row).min() { end = cross }
            var tall = false
            if end <= start {
                // 从 start 开始的某个键 (或互相卡住的一组) 本身就高于 N 行: 至少前进一行, 再往下扩到没有键跨过
                tall = true
                end = start + 1
                while let cross = crossing(keys, at: end)?.map({ $0.row + $0.rowSpan }).max() { end = cross }
            }
            end = min(max(end, start + 1), totalRows)
            result.append(Subpage(rows: start..<end, isTall: tall || (end - start) > n))
            start = end
        }
        return result
    }

    /// 跨过 `line` 的键: row < line < row + rowSpan。
    private static func crossing(_ keys: [KeyCap], at line: Int) -> [KeyCap]? {
        let c = keys.filter { $0.row < line && line < $0.row + $0.rowSpan }
        return c.isEmpty ? nil : c
    }

    /// 能放下几行 (行高 40, 行距 8): N = floor((可用高度 + 8) / 48)。
    static func rowsThatFit(height: CGFloat) -> Int {
        max(0, Int(((height + rowGap) / (minRowHeight + rowGap)).rounded(.down)))
    }

    /// 超高子页里的行高: 让整段刚好放下 (例如 5 行放进 184 pt → 30.4), 28 pt 只是下限; 压到 28 还放不下就滚动。
    static func tallRowHeight(rows: Int, availableHeight: CGFloat) -> (rowHeight: CGFloat, scrolls: Bool) {
        let r = max(1, rows)
        let fit = (availableHeight - rowGap * CGFloat(r - 1)) / CGFloat(r)
        return fit >= tallMinRowHeight ? (fit, false) : (tallMinRowHeight, true)
    }

    /// 形态切换 / 调换后子页数量变化: 停在包含原来第一可见行的子页, 找不到就回到第 1 个。
    static func subpageIndex(containingRow row: Int, in pages: [Subpage]) -> Int {
        pages.firstIndex { $0.rows.contains(row) } ?? 0
    }

    /// 形态切换后的新锚点 (M3 审计 I5): 停在包含旧锚点行的子页, 返回这个子页的实际首行; 下一次再变化就从它出发。
    static func reanchor(row: Int, in pages: [Subpage]) -> Int {
        guard !pages.isEmpty else { return row }
        return pages[subpageIndex(containingRow: row, in: pages)].rows.lowerBound
    }

    /// 取子页里的键并把行号重排到从 0 开始 (只含完整落在这个子页里的键)。
    static func keys(in subpage: Subpage, from keys: [KeyCap]) -> [KeyCap] {
        keys.filter { $0.row >= subpage.rows.lowerBound && $0.row + $0.rowSpan <= subpage.rows.upperBound }
            .map { var k = $0; k.row -= subpage.rows.lowerBound; return k }
    }
}

/// 内屏网格这一刻实际画出的键 (M3 审计 R-I1): 渲染和「面板锚点还在不在」用同一个计算, 覆盖子页和语音挡住的行。
struct InnerGridShown: Equatable {
    /// 当前子页的键
    var keys: [KeyCap]
    /// 完整露在可见高度里的键 (行底 ≤ visibleHeight); 没有遮挡时等于 keys
    var shown: [KeyCap]
    var rowHeight: CGFloat
    var gridHeight: CGFloat
    var scrolls: Bool

    /// - Parameters:
    ///   - height: 网格区的高度
    ///   - visibleHeight: 语音面板压在网格上时, 网格顶到面板之上的可见高度; nil = 没有遮挡
    static func compute(pageKeys: [KeyCap], rowCount: Int, subpages: [Subpage], subIdx: Int,
                        height: CGFloat, visibleHeight: CGFloat?) -> InnerGridShown {
        let sp = subpages.indices.contains(subIdx) ? subpages[subIdx] : Subpage(rows: 0..<max(1, rowCount), isTall: false)
        let keys = subpages.isEmpty ? pageKeys : SubpageSplitter.keys(in: sp, from: pageKeys)
        let rows = max(1, sp.rows.count)
        let gap = SubpageSplitter.rowGap
        let tall = sp.isTall ? SubpageSplitter.tallRowHeight(rows: rows, availableHeight: height) : nil
        let fill = (height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let rowH = tall?.rowHeight ?? min(DuoPolicy.standard.maxKeyRowHeight, max(SubpageSplitter.minRowHeight, fill))
        let gridH = tall?.scrolls == true ? height : min(height, CGFloat(rows) * rowH + CGFloat(rows - 1) * gap)
        let shown = visibleHeight.map { vh in
            keys.filter { CGFloat($0.row + $0.rowSpan) * (rowH + gap) - gap <= vh + 0.5 }
        } ?? keys
        return InnerGridShown(keys: keys, shown: shown, rowHeight: rowH, gridHeight: gridH, scrolls: tall?.scrolls ?? false)
    }
}
