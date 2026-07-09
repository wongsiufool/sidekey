import SwiftUI

/// 渲染一层「网格」布局。每个键按 col / row / colSpan / rowSpan 定位。
/// editing=true 时: 点键 = 编辑 (拖动移位 / 缩放手柄在 B2 加入); 否则点键 = 发送。
struct KeyboardView: View {
    let layer: KeyLayer
    var editing: Bool = false
    let connected: Bool
    var permissionMode: PermissionMode = .ask
    var effortLevel: EffortLevel = .high
    var client: SidekeyClient? = nil          // 触控板要靠它发鼠标事件 (普通键走 onKey 即可)
    let onKey: (KeyCap) -> Void
    var onEdit: (KeyCap) -> Void = { _ in }

    private let gap: CGFloat = 8
    private let cellH: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            if editing {
                ScrollView(.vertical, showsIndicators: false) {
                    gridBody(width: geo.size.width, cellH: cellH)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                gridBody(width: geo.size.width, cellH: fillCellH(geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    /// 非编辑态: 行高按可用高度等分, 让键盘铺满整屏 (键更大、无大块留白)。
    private func fillCellH(_ height: CGFloat) -> CGFloat {
        let rows = max(1, layer.rowCount)
        let h = (height - gap * CGFloat(max(0, rows - 1))) / CGFloat(rows)
        return max(40, h)
    }

    private func gridBody(width: CGFloat, cellH: CGFloat) -> some View {
        let cols = max(1, layer.columns)
        let cellW = max(1, (width - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let rows = layer.rowCount
        let totalH = CGFloat(rows) * cellH + CGFloat(max(0, rows - 1)) * gap
        return ZStack(alignment: .topLeading) {
            if editing && layer.keys.isEmpty {
                Text("本页暂无按键 —— 点下方「加键」开始")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(width: width, height: cellH * 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                            .foregroundStyle(.gray.opacity(0.4))
                    )
            }
            ForEach(layer.keys) { cap in
                keyView(cap)
                    .frame(width: cellW * CGFloat(cap.colSpan) + gap * CGFloat(cap.colSpan - 1),
                           height: cellH * CGFloat(cap.rowSpan) + gap * CGFloat(cap.rowSpan - 1))
                    .offset(x: CGFloat(cap.col) * (cellW + gap),
                            y: CGFloat(cap.row) * (cellH + gap))
            }
        }
        .frame(width: width, height: max(totalH, cellH), alignment: .topLeading)
    }

    @ViewBuilder
    private func keyView(_ cap: KeyCap) -> some View {
        if editing {
            KeyTile(cap: cap, enabled: true, permissionMode: permissionMode, effortLevel: effortLevel)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(4)
                        .background(Circle().fill(.yellow))
                        .padding(4)
                }
                .contentShape(Rectangle())
                .onTapGesture { onEdit(cap) }
        } else if cap.kind == .trackpad, let client {
            TrackpadView(client: client, enabled: connected)
        } else if cap.kind == .mouseButton, let client {
            MouseKeyButton(cap: cap, client: client, enabled: connected)
        } else {
            // permission/effort 都要把命令发给电脑才有意义 → 未连接时禁用 (与普通键一致); 只有切层键离线也可点。
            KeyCapButton(cap: cap,
                         enabled: connected || cap.kind == .layer,
                         // 只让真正适合连发的键连发 (退格/方向/空格); Enter/Esc/字母/数字/修饰键不连发, 杜绝误长按。
                         repeatable: cap.kind == .normal && cap.sendText == nil && cap.mods.isEmpty
                            && ["backspace", "left", "right", "up", "down", "space"].contains(cap.code.lowercased()),
                         permissionMode: permissionMode, effortLevel: effortLevel) { onKey(cap) }
        }
    }
}
