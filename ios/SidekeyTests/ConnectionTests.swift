import XCTest
@testable import Sidekey

/// 连接层纯逻辑测试 (审计 A 类补测): IPv6 URL 处理 + 失败分类契约。
final class ConnectionTests: XCTestCase {

    // MARK: - M-6: IPv6 字面量在 wss URL 里要加方括号

    func testBracketsIPv6Literal() {
        XCTAssertEqual(SidekeyClient.bracketedHost("fd00::1"), "[fd00::1]")
        XCTAssertEqual(SidekeyClient.bracketedHost("::1"), "[::1]")
        XCTAssertEqual(SidekeyClient.bracketedHost("2001:db8::abcd"), "[2001:db8::abcd]")
    }

    func testLeavesIPv4AndHostnameUnbracketed() {
        XCTAssertEqual(SidekeyClient.bracketedHost("192.168.1.20"), "192.168.1.20")
        XCTAssertEqual(SidekeyClient.bracketedHost("mac-mini.local"), "mac-mini.local")
    }

    func testDoesNotDoubleBracket() {
        XCTAssertEqual(SidekeyClient.bracketedHost("[fe80::1]"), "[fe80::1]")
    }

    func testTrimsWhitespaceBeforeBracketing() {
        XCTAssertEqual(SidekeyClient.bracketedHost("  fd00::1  "), "[fd00::1]")
        XCTAssertEqual(SidekeyClient.bracketedHost("  10.0.0.2 "), "10.0.0.2")
    }

    func testProducesValidURL() {
        // 端到端: 用 bracketedHost 拼出的 wss URL 必须能被 URL 解析 (IPv6 不加括号会解析失败)
        let h = SidekeyClient.bracketedHost("fd12:3456::7")
        XCTAssertNotNil(URL(string: "wss://\(h):8765"))
        let v4 = SidekeyClient.bracketedHost("192.168.1.5")
        XCTAssertNotNil(URL(string: "wss://\(v4):8765"))
    }

    // MARK: - 连接回调竞态: teardown 必须推进连接代次 (审计: Codex High-1)

    /// 旧 task 被取消后, 它晚到的 receive/didClose 回调靠「捕获代次 == 当前代次」来判废。
    /// 只要 teardown 每次都推进代次, 旧回调就会被守卫拦下、不污染新连接。这里锁住这个不变量:
    /// 若有人删掉 teardown 里的代次推进, 本测试立刻失败 (完整异步时序仍建议真机回归)。
    @MainActor
    func testTeardownAdvancesConnectionGeneration() {
        let c = SidekeyClient()
        let g0 = c.connectionGeneration
        c.disconnect()   // disconnect → teardown → 代次必须 +1
        XCTAssertGreaterThan(c.connectionGeneration, g0,
            "teardown 未推进 connectionGeneration —— 旧 task 的 receive/didClose 回调将不再被守卫拦截, 会清掉新连接的 task/状态")
    }

    // MARK: - TOFU 指纹归属: 切换电脑后旧握手的迟到 challenge 必须判废 (审计复审 #4)

    /// 锁住不变量: 一次握手发起时捕获的连接代次, 在 teardown(切换电脑/重连)后必须不再是「当前代次」。
    /// challenge 消费 TOFU 指纹前用 isCurrentGeneration 把关 —— 若此不变量被破坏, A 的证书指纹可能被错安到 B。
    /// (完整 TLS 异步时序仍建议真机回归。)
    @MainActor
    func testStaleHandshakeGenerationRejectedAfterSwitch() {
        let c = SidekeyClient()
        let genAtHandshake = c.connectionGeneration           // 模拟: 连 A 发起握手时捕获的代次
        XCTAssertTrue(c.isCurrentGeneration(genAtHandshake),
            "刚发起握手时应被视为当前代次 → TOFU 指纹可采纳")
        c.disconnect()                                        // 切到别的电脑 / 断开 → teardown → 代次推进
        XCTAssertFalse(c.isCurrentGeneration(genAtHandshake),
            "切换/重连后旧握手代次未判废 —— 迟到的 TOFU 指纹可能被错误安到新电脑")
    }
}
