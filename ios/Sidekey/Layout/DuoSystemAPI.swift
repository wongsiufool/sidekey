import SwiftUI

/// 层 1 采集里用到 iOS 27.1 新 API 的部分 (`reservedRegions`、`onHingeChange`), **全部集中在这个文件** (CLAUDE.md)。
/// - 旧 SDK 编译: `#if canImport(SwiftUI, _version: 8.0.85)` 整段跳过 (门槛同 Debug/DuoProbeAPI.swift);
/// - iOS 27.1 之前运行: `#available` 返回「没有保留区、没有铰链」, 布局按没有折痕处理。
enum DuoSystemAPI {
    /// 读保留区, 换算到窗口坐标。`proxy` 是尊重安全区的 GeometryReader:
    /// 系统返回的 frame 在 proxy 自己的坐标里 (原点在安全区左上角, M0 实测: 笔记本姿势显示状态栏时 division y = 373.5 = 455.5 − 82),
    /// 所以加上安全区的左、上两边就是窗口坐标。
    static func regions(_ proxy: GeometryProxy) -> [DuoRegion] {
        #if canImport(SwiftUI, _version: 8.0.85)
        guard #available(iOS 27.1, *) else { return [] }
        let dx = proxy.safeAreaInsets.leading, dy = proxy.safeAreaInsets.top
        func map(_ kind: DuoRegion.Kind, _ list: [ReservedRegion]) -> [DuoRegion] {
            list.map { DuoRegion(kind: kind, frame: $0.frame.offsetBy(dx: dx, dy: dy), isActive: $0.isActive) }
        }
        return map(.division, proxy.reservedRegions(kind: .division, options: .includeInactive))
             + map(.occlusion, proxy.reservedRegions(kind: .occlusion, options: .includeInactive))
        #else
        return []
        #endif
    }
}

extension View {
    /// 铰链状态写进 binding; 旧系统 / 旧 SDK / 没有铰链时保持 .unknown。
    func duoHinge(_ hinge: Binding<DuoHinge>) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return AnyView(modifier(DuoHingeModifier(hinge: hinge)))
        }
        #endif
        return AnyView(self)
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct DuoHingeModifier: ViewModifier {
    @Binding var hinge: DuoHinge

    func body(content: Content) -> some View {
        content.onHingeChange { _, ctx in
            hinge = ctx.hinge.map { DuoHingeModifier.map(String(describing: $0.status)) } ?? .unknown
        }
    }

    /// 只认三种状态; 角度不作判断条件 (§3.4), 这里不读。
    static func map(_ status: String) -> DuoHinge {
        switch status {
        case "closed": return .closed
        case "partiallyOpen": return .partiallyOpen
        case "fullyOpen": return .fullyOpen
        default: return .unknown
        }
    }
}
#endif
