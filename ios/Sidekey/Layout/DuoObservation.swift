import CoreGraphics

// 层 1「采集」的数据 (§7): 观测快照。读系统 API 的部分在 DuoSystemAPI.swift (iOS 27.1 隔离);
// 这里只有数据类型和纯函数的归一化, 便于单测。

/// 系统返回的保留区 (reservedRegions)。frame 一律换算到**窗口坐标** (原点 = 窗口左上角, 还没扣安全区)。
struct DuoRegion: Equatable {
    enum Kind: String, Equatable { case division, occlusion }
    var kind: Kind
    var frame: CGRect
    var isActive: Bool
}

/// 铰链状态。拿不到 (旧系统、没有铰链) = unknown, 按全开处理 (§3.4)。
enum DuoHinge: String, Equatable { case unknown, closed, partiallyOpen, fullyOpen }

/// 安全区 (窗口坐标里四条边各扣多少)。不做对称假设 (CLAUDE.md: 不写 left * 2)。
struct DuoInsets: Equatable {
    var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
}

/// 观测快照: 一个窗口在某一刻的原始几何。层 2 拿它做防抖, 层 3 拿它算布局。
struct DuoObservation: Equatable {
    var screen: ScreenKind
    var window: CGSize
    var safe: DuoInsets
    var regions: [DuoRegion]
    var hinge: DuoHinge

    static let empty = DuoObservation(screen: .phone, window: .zero, safe: DuoInsets(), regions: [], hinge: .unknown)

    var windowRect: CGRect { CGRect(origin: .zero, size: window) }

    /// 归一化 (§3.8 第 1 条): 丢掉对不上当前窗口的保留区。开合过渡的几帧里, 系统会带着上一块屏的旧区域 (坐标系不对)。
    /// - 手机屏 (外屏、普通 iPhone) 没有内部折痕: 丢掉全部 division (外屏刚出现时还带着内屏的 division);
    /// - 和窗口不相交、或宽高 ≤ 0 的区域: 丢掉;
    /// - 其余照常保留, 交给层 2 的防抖等它稳定 (例如刚回内屏时带着的外屏摄像头区)。
    func normalized() -> DuoObservation {
        var o = self
        let w = windowRect
        o.regions = regions.filter { r in
            guard r.frame.width > 0, r.frame.height > 0, r.frame.intersects(w) else { return false }
            if screen == .phone, r.kind == .division { return false }
            return true
        }
        return o
    }
}
