import XCTest
@testable import Sidekey

/// 权限模式 / 思考强度按电脑存 + 迁移 (§4.7, 评审确认: 复制给全部已有电脑, 幂等, 旧 key 保留)。
@MainActor
final class PerComputerStoreTests: XCTestCase {
    private func defaults(_ n: String) -> UserDefaults { let d = UserDefaults(suiteName: n)!; d.removePersistentDomain(forName: n); return d }

    func testMigratesGlobalValuesToAllExistingComputersAndKeepsLegacyKeys() {
        let d = defaults("pc1")
        d.set(PermissionMode.acceptEdits.rawValue, forKey: PerComputerStore.legacyPermissionKey)
        d.set(EffortLevel.low.rawValue, forKey: PerComputerStore.legacyEffortKey)
        let a = UUID(), b = UUID()
        let s = PerComputerStore(defaults: d, computerIDs: [a, b])
        XCTAssertEqual(s.permissionRaw(for: a), PermissionMode.acceptEdits.rawValue)
        XCTAssertEqual(s.permissionRaw(for: b), PermissionMode.acceptEdits.rawValue)
        XCTAssertEqual(s.effortRaw(for: b), EffortLevel.low.rawValue)
        XCTAssertNotNil(d.object(forKey: PerComputerStore.legacyPermissionKey), "旧全局 key 保留")
        // 新电脑用默认值
        XCTAssertEqual(s.permissionRaw(for: UUID()), PermissionMode.ask.rawValue)
        XCTAssertEqual(s.effortRaw(for: UUID()), EffortLevel.high.rawValue)
    }

    func testMigrationIsIdempotentAndPerComputerAfterwards() {
        let d = defaults("pc2")
        d.set(PermissionMode.plan.rawValue, forKey: PerComputerStore.legacyPermissionKey)
        let a = UUID(), b = UUID()
        let s1 = PerComputerStore(defaults: d, computerIDs: [a, b])
        s1.setPermission(PermissionMode.ask.rawValue, for: a)          // 只改 A
        d.set(PermissionMode.acceptEdits.rawValue, forKey: PerComputerStore.legacyPermissionKey)   // 旧 key 之后再变也不影响
        let s2 = PerComputerStore(defaults: d, computerIDs: [a, b])    // 再次启动: 不重新迁移
        XCTAssertEqual(s2.permissionRaw(for: a), PermissionMode.ask.rawValue)
        XCTAssertEqual(s2.permissionRaw(for: b), PermissionMode.plan.rawValue)
    }

    func testPruneRemovesDeletedComputers() {
        let d = defaults("pc3")
        let a = UUID(), b = UUID()
        let s = PerComputerStore(defaults: d, computerIDs: [a, b])
        s.setEffort(EffortLevel.low.rawValue, for: a); s.setEffort(EffortLevel.low.rawValue, for: b)
        s.prune(keeping: [a])
        XCTAssertEqual(s.effortRaw(for: a), EffortLevel.low.rawValue)
        XCTAssertEqual(s.effortRaw(for: b), EffortLevel.high.rawValue)
    }
}
