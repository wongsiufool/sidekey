import SwiftUI
import UIKit

/// 网格编辑器 (brief C2): 点键 = 选中(珊瑚描边 + 角落编辑 + 缩放手柄); 长按拖 = 移动; 拖手柄 = 改大小。
/// 极浅珊瑚点阵参考线。移动/缩放实时显示 绿=放得下 / 红=放不下; 放不下松手 → 错误震动 + 弹簧弹回。
struct GridEditorView: View {
    let layer: KeyLayer
    @Binding var selectedID: UUID?
    var canPlace: (UUID, Int, Int, Int, Int) -> Bool = { _, _, _, _, _ in true }
    var onMove: (UUID, Int, Int) -> Void = { _, _, _ in }
    var onResize: (UUID, Int, Int) -> Void = { _, _, _ in }
    var onEdit: (KeyCap) -> Void = { _ in }
    @Environment(\.sidekeyTheme) private var theme

    private let gap: CGFloat = 8
    private let cellH: CGFloat = 58
    private let topPad: CGFloat = 8

    @State private var dragID: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var moveCol = 0
    @State private var moveRow = 0
    @State private var moveValid = true
    @State private var resizeID: UUID?
    @State private var previewCols = 1
    @State private var previewRows = 1
    @State private var resizeValid = true

    var body: some View {
        GeometryReader { geo in
            let cols = max(1, layer.columns)
            let cellW = max(1, (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
            let stepX = cellW + gap
            let stepY = cellH + gap
            let rows = layer.rowCount + 2
            let totalH = topPad + CGFloat(rows) * cellH + CGFloat(rows - 1) * gap

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
                        .fill(theme.surfaceMuted.opacity(0.6))
                        .frame(width: geo.size.width, height: totalH)
                    guides(cols: cols, rows: rows, cellW: cellW, stepX: stepX, stepY: stepY)
                        .frame(width: geo.size.width, height: totalH)
                    Color.clear
                        .frame(width: geo.size.width, height: totalH)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = nil }

                    if let id = dragID, let cap = layer.keys.first(where: { $0.id == id }) {
                        moveGhost(cap, cellW: cellW, stepX: stepX, stepY: stepY)
                    }
                    if layer.keys.isEmpty {
                        Text("本页暂无按键 —— 点下方「新增按键」开始")
                            .font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                            .frame(width: geo.size.width, height: cellH * 1.5)
                            .offset(y: topPad)
                    }
                    ForEach(layer.keys) { cap in
                        cell(cap, cellW: cellW, stepX: stepX, stepY: stepY)
                    }
                }
                .frame(width: geo.size.width, height: totalH, alignment: .topLeading)
            }
        }
    }

    /// 极浅珊瑚点阵参考线。
    private func guides(cols: Int, rows: Int, cellW: CGFloat, stepX: CGFloat, stepY: CGFloat) -> some View {
        Canvas { ctx, _ in
            let dot: CGFloat = 3
            for r in 0...rows {
                for c in 0...cols {
                    let x = CGFloat(c) * stepX - gap / 2
                    let y = topPad + CGFloat(r) * stepY - gap / 2
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    ctx.fill(Path(ellipseIn: rect), with: .color(theme.accent.opacity(0.18)))
                }
            }
        }
    }

    private func moveGhost(_ cap: KeyCap, cellW: CGFloat, stepX: CGFloat, stepY: CGFloat) -> some View {
        let w = cellW * CGFloat(cap.colSpan) + gap * CGFloat(cap.colSpan - 1)
        let h = cellH * CGFloat(cap.rowSpan) + gap * CGFloat(cap.rowSpan - 1)
        let color = moveValid ? theme.success : theme.danger
        return RoundedRectangle(cornerRadius: theme.radiusKey)
            .fill(color.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusKey)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [6])))
            .frame(width: w, height: h)
            .offset(x: CGFloat(moveCol) * stepX, y: topPad + CGFloat(moveRow) * stepY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cell(_ cap: KeyCap, cellW: CGFloat, stepX: CGFloat, stepY: CGFloat) -> some View {
        let isSel = selectedID == cap.id
        let isDragging = dragID == cap.id
        let isResizing = resizeID == cap.id
        let w = cellW * CGFloat(cap.colSpan) + gap * CGFloat(cap.colSpan - 1)
        let h = cellH * CGFloat(cap.rowSpan) + gap * CGFloat(cap.rowSpan - 1)
        let pw = cellW * CGFloat(previewCols) + gap * CGFloat(previewCols - 1)
        let ph = cellH * CGFloat(previewRows) + gap * CGFloat(previewRows - 1)
        let x = CGFloat(cap.col) * stepX + (isDragging ? dragOffset.width : 0)
        let y = topPad + CGFloat(cap.row) * stepY + (isDragging ? dragOffset.height : 0)
        let resizeColor = resizeValid ? theme.success : theme.danger

        KeyTile(cap: cap, enabled: true, selected: isSel)
            .frame(width: w, height: h)
            .overlay(alignment: .topLeading) {
                if isResizing {
                    RoundedRectangle(cornerRadius: theme.radiusKey)
                        .fill(resizeColor.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: theme.radiusKey)
                            .strokeBorder(resizeColor, style: StrokeStyle(lineWidth: 2, dash: [6])))
                        .frame(width: pw, height: ph)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSel && !isDragging {
                    Button { onEdit(cap) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white).frame(width: 28, height: 28)
                            .background(Circle().fill(theme.accent))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 10, y: -10)
                }
            }
            .overlay(alignment: .trailing) {
                if isSel && !isDragging { handle(cap, dx: true, dy: false, stepX: stepX, stepY: stepY).offset(x: 4) }
            }
            .overlay(alignment: .bottom) {
                if isSel && !isDragging { handle(cap, dx: false, dy: true, stepX: stepX, stepY: stepY).offset(y: 4) }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSel && !isDragging { handle(cap, dx: true, dy: true, stepX: stepX, stepY: stepY).offset(x: 4, y: 4) }
            }
            .scaleEffect(isDragging ? 1.06 : 1)
            .opacity(isDragging ? 0.85 : 1)
            .offset(x: x, y: y)
            .zIndex(isDragging || isResizing ? 100 : (isSel ? 10 : 0))
            .onTapGesture { selectedID = isSel ? nil : cap.id }
            .gesture(moveGesture(cap, stepX: stepX, stepY: stepY))
    }

    private func handle(_ cap: KeyCap, dx: Bool, dy: Bool, stepX: CGFloat, stepY: CGFloat) -> some View {
        Circle()
            .fill(theme.accent)
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        resizeID = cap.id
                        let dCols = dx ? Int((v.translation.width / stepX).rounded()) : 0
                        let dRows = dy ? Int((v.translation.height / stepY).rounded()) : 0
                        previewCols = max(1, cap.colSpan + dCols)
                        previewRows = max(1, cap.rowSpan + dRows)
                        resizeValid = canPlace(cap.id, cap.col, cap.row, previewCols, previewRows)
                    }
                    .onEnded { _ in
                        if resizeValid { onResize(cap.id, previewCols, previewRows) }
                        else { UINotificationFeedbackGenerator().notificationOccurred(.error) }
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) { resizeID = nil }
                    }
            )
    }

    private func moveGesture(_ cap: KeyCap, stepX: CGFloat, stepY: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    if dragID != cap.id {
                        dragID = cap.id
                        selectedID = cap.id
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    dragOffset = drag.translation
                    let col = max(0, cap.col + Int((drag.translation.width / stepX).rounded()))
                    let row = max(0, cap.row + Int((drag.translation.height / stepY).rounded()))
                    if col != moveCol || row != moveRow {
                        moveCol = col
                        moveRow = row
                        moveValid = canPlace(cap.id, col, row, cap.colSpan, cap.rowSpan)
                    }
                }
            }
            .onEnded { value in
                if case .second(true, _) = value {
                    if moveValid { onMove(cap.id, moveCol, moveRow) }
                    else { UINotificationFeedbackGenerator().notificationOccurred(.error) }
                }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                    dragID = nil
                    dragOffset = .zero
                }
            }
    }
}
