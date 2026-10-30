import SwiftUI

/// App 级共享状态 (§7): 所有窗口共用, 只创建一次。
/// - 现在: `LayoutStore`、按电脑的状态、主题、局域网发现、连接池和唯一的一条连接 (M1)。
/// - 之后: 语音面板占用 (M5)、编辑锁 (M5) 按同样方式挂在这里。
/// 窗口级状态 (当前电脑 / 模式 / 页 / 子页等) 在 `WindowState`, 不在这里。
/// 根视图上「未保存」状态条占的高度: 根视图的 GeometryReader 在状态条内缩之后只拿到剩下的内容区, 判断横竖屏 / 要不要侧栏要按**完整窗口**的形状 (v1.8 补充)。
@MainActor
final class UnsavedBannerLayout: ObservableObject {
    @Published var rootHeight: CGFloat = 0
    /// 竖屏时「键盘区以外」的外围控件占的高度 (顶栏、分页条、底栏、内边距: 窗口内容区高度 − 键盘区高度); 横屏时为 nil。状态条据此算真实输入区预算。
    @Published var portraitNonInput: CGFloat?
    /// 竖屏键盘区当前高度 (太小时显示「窗口太小」占位)。
    @Published var portraitPagerHeight: CGFloat = .infinity
}

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let defaults: UserDefaults
    let store: LayoutStore
    let perComputer: PerComputerStore
    let bannerLayout = UnsavedBannerLayout()
    let themeManager: ThemeManager
    let discovery: Discovery
    let client: SidekeyClient
    let connections: ConnectionPool
    /// 鼠标键按住仲裁 (按「电脑 + 键」, 所有窗口共用, §4.7)。
    let mouseArbiter = InputGuard.ArbiterBox()

    private init() {
        // UI 测试时用一份干净的 UserDefaults, 且只清一次 (以前每次 resolve 都清, 会把刚建好的数据抹掉)。
        let d = AppDefaults.resolve()
        defaults = d
        let store = LayoutStore(defaults: d)
        self.store = store
        perComputer = PerComputerStore(defaults: d, computerIDs: store.computers.map(\.id))
        themeManager = ThemeManager(defaults: d)
        discovery = Discovery()
        let client = SidekeyClient()
        self.client = client
        client.credentialCacheWriteAllowed = { [weak store] in !(store?.hasUnsavedChanges ?? false) }
        connections = ConnectionPool(transport: .init(
            connect: { [weak store, weak client] id in
                guard let store, let client else { return }
                store.retryUnreadableTokens()                                    // 先重读, 再取配置 (重读成功后用的是恢复了令牌的那份)
                guard let c = store.computers.first(where: { $0.id == id }) else { return }
                if store.isTokenUnknown(id) { client.disconnect(); return }      // 令牌暂时读不出来: 不按「没有令牌」去连接
                if c.host.isEmpty { client.disconnect() } else { client.connect(to: c) }
            },
            disconnect: { [weak client] id in
                // M1 只有一条连接: 只有它连的正是这台电脑时才断, 免得误断刚连上的新电脑。
                guard let client, client.connectedComputerID == id else { return }
                client.disconnect()
            }))
    }
}
