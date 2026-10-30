import XCTest
@testable import Sidekey

/// T-SC-1 [M1]: 判屏规则 (§3.1)。
final class ScreenContextTests: XCTestCase {
    private func probe(_ w: Double?, _ h: Double?, model: String? = "iPhone19,4", os: Bool = true,
                       zoom: Bool? = true, ext: Bool? = false) -> ScreenProbe {
        ScreenProbe(osSupportsDuoAPI: os, boundsWidth: w, boundsHeight: h, modelIdentifier: model,
                    isDefaultDisplayZoom: zoom, isMirroredOrExternal: ext)
    }

    func testDuoInnerScreenAllShapes() {
        XCTAssertEqual(ScreenContext.classify(probe(669, 951)), .inner)   // 竖向
        XCTAssertEqual(ScreenContext.classify(probe(951, 669)), .inner)   // 横向; Split View 窄窗口读到的仍是整块屏
    }

    func testDuoOuterScreenIsPhone() {
        XCTAssertEqual(ScreenContext.classify(probe(466, 678)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(678, 466)), .phone)
    }

    // 所有在售 iPhone 尺寸 (含 Pro Max、iPhone Air) 都是手机屏, 即使机型标识恰好在清单里也一样 (短边 < 600)。
    func testAllPhonesArePhone() {
        let sizes: [(Double, Double)] = [(375, 667), (390, 844), (393, 852), (402, 874), (430, 932), (440, 956), (420, 912), (874, 402), (956, 440)]
        for (w, h) in sizes {
            XCTAssertEqual(ScreenContext.classify(probe(w, h)), .phone, "\(w)x\(h)")
            XCTAssertEqual(ScreenContext.classify(probe(w, h, model: "iPhone18,1")), .phone, "\(w)x\(h)")
        }
    }

    // 清单外一律手机屏: 其他机型、显示缩放、镜像/外接、系统太旧、读不到。
    func testOutsideSupportedListIsPhone() {
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, model: "iPhone18,1")), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, model: nil)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, zoom: false)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, zoom: nil)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, ext: true)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, ext: nil)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(669, 951, os: false)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(nil, nil)), .phone)
        XCTAssertEqual(ScreenContext.classify(probe(0, 0)), .phone)
    }

    func testThresholdBoundary() {
        XCTAssertEqual(ScreenContext.classify(probe(600, 900)), .inner)
        XCTAssertEqual(ScreenContext.classify(probe(599.5, 900)), .phone)
    }
}
