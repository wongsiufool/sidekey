import XCTest
@testable import Sidekey

/// 第 4 阶段「扫码配对」的配对码解析测试。
final class PairingTests: XCTestCase {

    func testParseServerPayload() {
        let raw = #"{"v":1,"hosts":["192.168.1.254","10.0.0.2"],"port":8765,"token":"abc123"}"#
        let p = PairingPayload.parse(raw)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.hosts.first, "192.168.1.254")
        XCTAssertEqual(p?.hosts.count, 2)
        XCTAssertEqual(p?.port, 8765)
        XCTAssertEqual(p?.token, "abc123")
    }

    func testParseTolueratesWhitespace() {
        let raw = "  {\"v\":1,\"hosts\":[\"1.2.3.4\"],\"port\":9000,\"token\":\"t\"}\n"
        XCTAssertEqual(PairingPayload.parse(raw)?.port, 9000)
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(PairingPayload.parse("not a qr code"))
        XCTAssertNil(PairingPayload.parse(""))
        XCTAssertNil(PairingPayload.parse("{ broken json"))
    }

    func testRoundTrip() throws {
        let p = PairingPayload(v: 1, hosts: ["a", "b"], port: 8765, token: "xyz")
        let data = try JSONEncoder().encode(p)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertEqual(PairingPayload.parse(s), p)
    }

    // MARK: - 语义校验 (审计 M-2): 结构正确但语义非法的配对码必须被拒, 不存成连不上的电脑

    func testRejectsEmptyHost() {
        let raw = #"{"v":1,"hosts":[""],"port":8765,"token":"t"}"#
        XCTAssertNil(PairingPayload.parse(raw))
        XCTAssertThrowsError(try PairingPayload.validated(raw)) { err in
            XCTAssertEqual(err as? PairingPayload.ParseError, .noHost)
        }
    }

    func testRejectsBadPort() {
        XCTAssertNil(PairingPayload.parse(#"{"v":1,"hosts":["1.2.3.4"],"port":0,"token":"t"}"#))
        XCTAssertNil(PairingPayload.parse(#"{"v":1,"hosts":["1.2.3.4"],"port":70000,"token":"t"}"#))
        XCTAssertThrowsError(try PairingPayload.validated(#"{"v":1,"hosts":["1.2.3.4"],"port":0,"token":"t"}"#)) {
            XCTAssertEqual($0 as? PairingPayload.ParseError, .badPort)
        }
    }

    func testRejectsUnsupportedVersion() {
        let raw = #"{"v":2,"hosts":["1.2.3.4"],"port":8765,"token":"t"}"#
        XCTAssertNil(PairingPayload.parse(raw))
        XCTAssertThrowsError(try PairingPayload.validated(raw)) {
            XCTAssertEqual($0 as? PairingPayload.ParseError, .unsupportedVersion)
        }
    }

    func testRejectsBadFingerprint() {
        // 太短
        XCTAssertNil(PairingPayload.parse(#"{"v":1,"hosts":["1.2.3.4"],"port":8765,"token":"t","fp":"abcd"}"#))
        // 含非十六进制字符
        let nonHex = #"{"v":1,"hosts":["1.2.3.4"],"port":8765,"token":"t","fp":"\#(String(repeating: "z", count: 64))"}"#
        XCTAssertThrowsError(try PairingPayload.validated(nonHex)) {
            XCTAssertEqual($0 as? PairingPayload.ParseError, .badFingerprint)
        }
    }

    func testAcceptsValid64HexFingerprint() {
        let fp = String(repeating: "a1", count: 32)   // 64 位十六进制
        let raw = #"{"v":1,"hosts":["192.168.1.5"],"port":8765,"token":"tok","fp":"\#(fp)"}"#
        let p = PairingPayload.parse(raw)
        XCTAssertEqual(p?.fp, fp)
        XCTAssertEqual(p?.hosts.first, "192.168.1.5")
    }

    func testAcceptsMissingFingerprintTOFU() {
        // 无 fp(旧配对码 / TOFU)仍合法
        XCTAssertNotNil(PairingPayload.parse(#"{"v":1,"hosts":["1.2.3.4"],"port":8765,"token":"t"}"#))
    }

    // MARK: - 失败分类 (审计 H-3): needsRepair 决定主屏/卡片把哪个按钮作主操作

    func testFailureNeedsRepairMapping() {
        // 令牌/证书类 → 重新扫码配对(重试无用)
        XCTAssertTrue(SidekeyClient.FailureKind.token.needsRepair)
        XCTAssertTrue(SidekeyClient.FailureKind.tls.needsRepair)
        // 网络类 → 重试
        XCTAssertFalse(SidekeyClient.FailureKind.address.needsRepair)
        XCTAssertFalse(SidekeyClient.FailureKind.timeout.needsRepair)
        XCTAssertFalse(SidekeyClient.FailureKind.network.needsRepair)
        XCTAssertFalse(SidekeyClient.FailureKind.send.needsRepair)
    }

    func testFailureCopyNonEmpty() {
        // 每类都要有短标题和详细说明(给药丸 / banner 用), 不能漏
        let kinds: [SidekeyClient.FailureKind] = [.address, .tls, .token, .timeout, .network, .send]
        for k in kinds {
            XCTAssertFalse(k.shortTitle.isEmpty, "\(k) 缺短标题")
            XCTAssertFalse(k.detail.isEmpty, "\(k) 缺详细说明")
        }
    }
}
