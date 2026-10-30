import XCTest
@testable import Sidekey

/// 存档读写的系统性边界测试 (自写 JSONParser / SidekeyJSON / LayoutStore 恢复流程)。
/// 原则: 任何读不懂、或「两套解析可能不一致」的存档, 都必须进恢复流程 —— 保留原档、写备份、恢复期间不写主存档; 读得懂的存档来回读写不丢任何数据。
@MainActor
final class PersistenceFidelityTests: XCTestCase {
    private let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }

    /// 带一个未知键 (自定义 payload 文本) 的完整存档。
    private func save(unknownPayload: String = #"{"x":1}"#, extraTopLevel: String = "", label: String = "U") -> Data {
        Data(#"{\#(extraTopLevel)"computers":[{"id":"\#(id)","name":"C","host":"","port":8765,"token":"","fingerprint":"","modes":[{"id":"\#(id)","name":"M","layers":[{"id":"base","columns":4,"keys":[{"id":"\#(id)","kind":"future","label":"\#(label)","payload":\#(unknownPayload)}]}]}],"lastModeID":"\#(id)"}],"currentComputerID":"\#(id)","currentModeID":"\#(id)","builtinVersion":11}"#.utf8)
    }

    // MARK: 完整 LayoutStore 流程: 读不懂的存档 → 恢复, 原档不被改写

    /// 断言一份坏存档走完整流程: 进恢复页、原档逐字节保留、有备份、恢复期间写入被挡住、选择继续后才写新档且备份仍在。
    private func assertRecoversWithoutOverwriting(_ raw: Data, _ name: String, beforeResolve: () -> Void = {}, file: StaticString = #filePath, line: UInt = #line) {
        let d = defaults("pf-" + name)
        d.set(raw, forKey: "sidekey.app.v5")
        let store = LayoutStore(defaults: d)
        XCTAssertNotNil(store.recovery, "\(name): 应进入恢复流程", file: file, line: line)
        XCTAssertEqual(store.recovery?.rawData, raw, "\(name): 恢复页拿到的是原始数据", file: file, line: line)
        XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), raw, "\(name): 原档逐字节保留 (首次启动就不改写)", file: file, line: line)
        XCTAssertTrue(LayoutStore.corruptBackupKeys(in: d).contains { d.data(forKey: $0) == raw }, "\(name): 有备份", file: file, line: line)
        _ = store.upsertComputer(name: "X", host: "1.2.3.4", port: 1, token: "t")          // 恢复期间的任何修改
        XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), raw, "\(name): 恢复期间写入被挡住", file: file, line: line)
        beforeResolve()
        store.resolveRecoveryWithFreshData()
        XCTAssertNotEqual(d.data(forKey: "sidekey.app.v5"), raw, "\(name): 选择继续后才写新档", file: file, line: line)
        XCTAssertTrue(LayoutStore.corruptBackupKeys(in: d).contains { d.data(forKey: $0) == raw }, "\(name): 备份仍在", file: file, line: line)
    }

    // MARK: 保存失败 = 保留草稿 (v1.8 §6.4 第 7 条, T-DATA-6)

    /// 把读取上限临时调到 `limit` (到期自动恢复)。
    private func withLimit(_ limit: Int, _ body: () -> Void) {
        let old = JSONParser.maxBytes
        defer { JSONParser.maxBytes = old }
        JSONParser.maxBytes = limit
        body()
    }

    // 超限: 内存保留修改 (照常可用), 存档和 Keychain 不变, 状态位 + 小标记置位; 返回值表示「修改已生效」。
    func testSaveBeyondReadLimitKeepsDraftInMemory() {
        let d = defaults("pf-draft")
        let store = LayoutStore(defaults: d)
        let before = d.data(forKey: "sidekey.app.v5")!
        let pages = store.layers.count
        withLimit(before.count / 2) {
            let id = store.addPage()
            XCTAssertNotNil(id, "返回值表示修改已经生效, 照常返回新页 id")
            XCTAssertEqual(store.layers.count, pages + 1, "内存保留修改")
            XCTAssertNotNil(store.addKey(layerID: id!)); XCTAssertNotNil(store.addMode(named: "草稿模式"))
            XCTAssertTrue(store.hasUnsavedChanges)
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), before, "存档仍是最后一次成功保存的内容")
            XCTAssertTrue(d.bool(forKey: LayoutStore.unsavedMarkerKey), "小标记置位")
        }
        // 数据变小 / 恢复到上限内: 下一次修改整份重存, 成功后状态清除, 之前累积的修改一起存进去
        _ = store.addPage()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertFalse(d.bool(forKey: LayoutStore.unsavedMarkerKey))
        let reopened = LayoutStore(defaults: d)
        XCTAssertEqual(reopened.layers.count, pages + 2)
        XCTAssertTrue(reopened.currentComputer!.modes.contains { $0.name == "草稿模式" }, "之前未保存的修改一并落盘")
    }

    // 「重试保存」仍然超限: 状态继续显示, 不变; 恢复后重试成功。
    func testRetryWhileStillOverLimitKeepsStateThenSucceeds() {
        let d = defaults("pf-retry")
        let store = LayoutStore(defaults: d)
        let before = d.data(forKey: "sidekey.app.v5")!
        withLimit(before.count / 2) {
            _ = store.addPage()
            XCTAssertFalse(store.retryUnsavedSave())
            XCTAssertFalse(store.retryUnsavedSave())
            XCTAssertTrue(store.hasUnsavedChanges)
        }
        XCTAssertTrue(store.retryUnsavedSave())
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertTrue(store.retryUnsavedSave(), "没有未保存修改时重试是空操作")
    }

    // 「放弃修改」: 恢复到最后一次成功保存的内容, 标记清除, 窗口修正信号递增。
    func testDiscardRestoresLastSavedContent() {
        let d = defaults("pf-discard")
        let store = LayoutStore(defaults: d)
        let savedCount = store.computers.count
        let before = d.data(forKey: "sidekey.app.v5")!
        let gen = store.discardGeneration
        withLimit(before.count / 2) {
            _ = store.upsertComputer(name: "新配对", host: "5.5.5.5", port: 1, token: "t-new")
            XCTAssertTrue(store.hasUnsavedChanges)
        }
        XCTAssertNil(KeychainToken.get(store.computers.last!.id.uuidString), "未保存期间 Keychain 一点都没改")
        store.discardUnsavedChanges()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(store.computers.count, savedCount, "新配对的电脑也被放弃")
        XCTAssertEqual(store.discardGeneration, gen + 1)
        XCTAssertFalse(d.bool(forKey: LayoutStore.unsavedMarkerKey))
        XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), before)
    }

    // 未保存时 App 被杀: 回到最后一次保存的内容, 下次启动提示一次, 之后不再提示。
    func testKilledWhileUnsavedRestoresAndNoticesOnce() {
        let d = defaults("pf-killed")
        var store: LayoutStore? = LayoutStore(defaults: d)
        let before = d.data(forKey: "sidekey.app.v5")!
        let pages = store!.layers.count
        withLimit(before.count / 2) { _ = store!.addPage() }
        XCTAssertTrue(store!.hasUnsavedChanges)
        store = nil                                                          // 模拟被杀
        let second = LayoutStore(defaults: d)
        XCTAssertEqual(second.layers.count, pages, "回到最后一次保存的内容")
        XCTAssertTrue(second.previousSessionLostChanges, "提示")
        XCTAssertFalse(second.hasUnsavedChanges)
        let third = LayoutStore(defaults: d)                                  // 提示还没显示 / 确认就再次启动: 不丢
        XCTAssertTrue(third.previousSessionLostChanges, "待确认提示: 确认前不清, 启动时的自动保存也不会提前清掉")
        third.acknowledgePreviousSessionLoss()
        XCTAssertFalse(LayoutStore(defaults: d).previousSessionLostChanges, "确认之后再启动不再提示")
    }

    // 保存失败期间删电脑: 凭证清理推迟到某次保存成功之后; 放弃修改则电脑和凭证都在。Keychain 在失败期间一点都不改。
    func testDeleteComputerWhileUnsavedDefersCredentialCleanup() {
        let d = defaults("pf-delete-unsaved")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        let b = store.upsertComputer(name: "B", host: "10.0.0.2", port: 2, token: "tok-B")
        defer { KeychainToken.delete(a.uuidString); KeychainToken.delete(b.uuidString) }
        let before = d.data(forKey: "sidekey.app.v5")!
        withLimit(before.count / 2) {
            XCTAssertTrue(store.deleteComputer(id: b))
            XCTAssertFalse(store.computers.contains { $0.id == b }, "内存里已删")
            XCTAssertEqual(KeychainToken.get(b.uuidString), "tok-B", "保存失败: 凭证不动")
        }
        store.discardUnsavedChanges()
        XCTAssertTrue(store.computers.contains { $0.id == b }, "放弃修改: 电脑回来")
        XCTAssertEqual(KeychainToken.get(b.uuidString), "tok-B")
        withLimit(before.count / 2) { _ = store.deleteComputer(id: b) }
        XCTAssertEqual(KeychainToken.get(b.uuidString), "tok-B")
        XCTAssertTrue(store.retryUnsavedSave())                                  // 保存成功之后才清凭证
        XCTAssertNil(KeychainToken.get(b.uuidString))
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-A")
    }

    // 编辑电脑: 名称 + 连接信息一起保存、一起未保存; 超限时存档与 Keychain 都不变。
    func testComputerEditIsAtomicAndKeychainUntouchedWhenUnsaved() {
        let d = defaults("pf-atomic-computer")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-old")
        defer { KeychainToken.delete(a.uuidString) }
        let saved = d.data(forKey: "sidekey.app.v5")!
        withLimit(saved.count + 50) {
            XCTAssertTrue(store.updateComputer(id: a, name: String(repeating: "N", count: 500), host: "9.9.9.9", port: 9, token: "tok-new", fingerprint: ""))
            XCTAssertTrue(store.hasUnsavedChanges)
            XCTAssertEqual(store.computer(a)?.host, "9.9.9.9"); XCTAssertEqual(store.computer(a)?.token, "tok-new", "内存里整体生效")
            XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-old", "Keychain 不变")
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), saved)
        }
        XCTAssertTrue(store.retryUnsavedSave())
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-new")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.host, "9.9.9.9")
    }

    // 所有可能落盘的形态都在动 Keychain 之前校验: 令牌抹掉的形态能存, 但 Keychain 写失败时的明文兜底形态会超限 → 整体当作保存失败, 凭证不变。
    func testWorstCaseTokenFormIsValidatedBeforeKeychainIsTouched() {
        let d = defaults("pf-worst-form")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-old")
        defer { KeychainToken.delete(a.uuidString) }
        let saved = d.data(forKey: "sidekey.app.v5")!
        withLimit(saved.count + 100) {                                       // 抹掉令牌的形态放得下, 带 600 字节明文令牌的形态放不下
            store.updateComputerConnection(id: a, host: "10.0.0.1", port: 1, token: String(repeating: "T", count: 600))
            XCTAssertTrue(store.hasUnsavedChanges)
            XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-old", "Keychain 里的旧令牌没被覆盖")
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), saved)
        }
    }

    // 启动迁移 / 第一次重新编码就超限: 内存保留 (按读到的状态 + 迁移), 存档原样, 状态位置位, 放弃后回到磁盘读到的状态。
    func testFirstSaveFailureAtLaunchKeepsOnDiskAndAllowsDiscard() {
        let d = defaults("pf-baseline")
        let raw = save()                                                      // 旧存档: 没有 mode.kind, 重新编码会变大
        d.set(raw, forKey: "sidekey.app.v5")
        withLimit(raw.count) {                                                // 读得进, 重新编码后放不下
            let store = LayoutStore(defaults: d)
            XCTAssertNil(store.recovery)
            XCTAssertTrue(store.hasUnsavedChanges, "启动时第一次重新编码被拒")
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), raw, "磁盘原样")
            store.discardUnsavedChanges()
            XCTAssertEqual(store.computers.count, 1)
            XCTAssertEqual(store.computers[0].modes.count, 1, "放弃后回到磁盘读到的状态")
        }
    }

    func testModeAndKeyOperationsReturnAppliedWhileUnsaved() {
        let d = defaults("pf-mode-key")
        let store = LayoutStore(defaults: d)
        let cap = store.layers[0].keys[0]
        let saved = d.data(forKey: "sidekey.app.v5")!
        withLimit(saved.count / 2) {
            XCTAssertNotNil(store.addMode(named: "新")); XCTAssertNotNil(store.duplicateMode(id: store.currentModeID))
            var changed = cap; changed.label = "改"
            XCTAssertTrue(store.updateKey(layerID: store.layers[0].id, cap: changed))
            XCTAssertTrue(store.selectMode(store.currentComputer!.modes.last!.id))
        }
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    // 阻断 1: 删 B → 保存失败 → 用同一个 id 加回 B 并更新令牌 → 保存成功: 新令牌不能被旧的清理误删。
    func testReAddingSameIDAfterFailedDeleteKeepsNewToken() {
        let d = defaults("pf-readd-same-id")
        let store = LayoutStore(defaults: d)
        _ = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        let b = store.upsertComputer(name: "B", host: "10.0.0.2", port: 2, token: "tok-B")
        defer { KeychainToken.delete(b.uuidString) }
        let bComputer = store.computer(b)!
        let saved = d.data(forKey: "sidekey.app.v5")!
        withLimit(saved.count / 2) { XCTAssertTrue(store.deleteComputer(id: b)) }
        XCTAssertTrue(store.hasUnsavedChanges)
        var back = bComputer; back.token = "tok-B-new"
        XCTAssertTrue(store.addComputer(back))                                // 同一个 id 加回来, 令牌换新, 保存成功
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertEqual(KeychainToken.get(b.uuidString), "tok-B-new", "新令牌不能被旧的删除清理冲掉")
        XCTAssertEqual(LayoutStore(defaults: d).computer(b)?.token, "tok-B-new")
    }

    // 凭证清理按最终数据: 记录持久化; 存档里确实没有的电脑在下次保存成功 / 启动时补做, 仍在的取消。
    func testCredentialCleanupRecordsAreReplayedFromFinalDataAtLaunch() {
        let d = defaults("pf-cred-cleanup")
        let orphan = UUID()
        let alive = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "alive-token")   // 经存储写入: 令牌在 Keychain 里
        _ = KeychainToken.set("orphan-token", for: orphan.uuidString)
        defer { KeychainToken.delete(orphan.uuidString); KeychainToken.delete(alive.uuidString) }
        d.set([orphan.uuidString, alive.uuidString], forKey: LayoutStore.credentialCleanupKey)    // 上次没做完的清理记录
        _ = LayoutStore(defaults: d)
        XCTAssertNil(KeychainToken.get(orphan.uuidString), "孤儿凭证启动时补做删除")
        XCTAssertEqual(KeychainToken.get(alive.uuidString), "alive-token", "存档里仍有这台电脑: 取消清理, 凭证保留")
        XCTAssertNil(d.stringArray(forKey: LayoutStore.credentialCleanupKey), "记录清空")
    }

    // 阻断 3: blob 里有明文令牌 (Keychain 写失败时的兜底, 比 Keychain 里的旧值新) → 加载以明文为准; blob 空才取 Keychain。
    func testPlaintextFallbackInBlobWinsOverStaleKeychain() {
        let d = defaults("pf-token-priority")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-in-keychain")
        defer { KeychainToken.delete(a.uuidString) }
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-in-keychain", "blob 里是空的: 取 Keychain")
        var blob = String(data: d.data(forKey: "sidekey.app.v5")!, encoding: .utf8)!
        blob = blob.replacingOccurrences(of: "\"host\":\"10.0.0.1\"", with: "\"host\":\"10.0.0.1\"")   // 结构不变, 下面只改令牌
        let range = blob.range(of: "\"token\":\"\"")!
        blob.replaceSubrange(range, with: "\"token\":\"fallback-newer\"")
        d.set(Data(blob.utf8), forKey: "sidekey.app.v5")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "fallback-newer", "明文兜底比 Keychain 里的旧值新")
    }

    // 放弃修改 / 失效目标: updateKey 页或键不存在时不应用、返回 false。
    func testUpdateKeyReturnsFalseForMissingTarget() {
        let store = LayoutStore(defaults: defaults("pf-updatekey-missing"))
        var ghost = store.layers[0].keys[0]; ghost.id = UUID()
        XCTAssertFalse(store.updateKey(layerID: store.layers[0].id, cap: ghost))
        XCTAssertFalse(store.updateKey(layerID: "no-such-page", cap: store.layers[0].keys[0]))
    }

    // 阻断 1: 恢复页状态下不清理凭证 (这时内存里是恢复用的默认数据, 证明不了原来的电脑已被删); 选择「继续」只丢记录、不删凭证。
    func testRecoveryStateNeverDeletesCredentials() {
        let d = defaults("pf-recovery-no-cleanup")
        let store = LayoutStore(defaults: d)
        _ = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        let b = store.upsertComputer(name: "B", host: "10.0.0.2", port: 2, token: "tok-B")
        defer { KeychainToken.delete(b.uuidString) }
        let saved = d.data(forKey: "sidekey.app.v5")!
        withLimit(saved.count / 2) { XCTAssertTrue(store.deleteComputer(id: b)) }          // 删 B 未保存, 清理记录已写
        XCTAssertNotNil(d.stringArray(forKey: LayoutStore.credentialCleanupKey))
        d.set(Data("{not json".utf8), forKey: "sidekey.app.v5")                           // 原存档损坏
        let recovering = LayoutStore(defaults: d)
        XCTAssertNotNil(recovering.recovery)
        XCTAssertEqual(KeychainToken.get(b.uuidString), "tok-B", "恢复状态下不删有效凭证")
        recovering.resolveRecoveryWithFreshData()
        XCTAssertEqual(KeychainToken.get(b.uuidString), "tok-B", "选择继续: 只丢清理记录, 不删凭证 (原来的电脑可能还在备份里)")
        XCTAssertNil(d.stringArray(forKey: LayoutStore.credentialCleanupKey))
    }

    // 阻断 2: 显式清空令牌 → 重启后仍为空 (Keychain 旧项一并删掉), 不会复活旧令牌。
    func testExplicitlyClearedTokenStaysClearedAfterRestart() {
        let d = defaults("pf-clear-token")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-old")
        defer { KeychainToken.delete(a.uuidString) }
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-old")
        store.updateComputerConnection(id: a, host: "10.9.9.9", port: 1, token: "")
        XCTAssertEqual(store.computer(a)?.token, "")
        XCTAssertNil(KeychainToken.get(a.uuidString), "Keychain 旧项一并删掉")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "", "重启后不复活旧令牌")
    }

    // 重要 3: current 缓存只在确实属于被删电脑 (令牌相同、没有别的电脑在用同一令牌) 时才清。
    func testCurrentCacheOnlyClearedWhenItBelongsToDeletedComputer() {
        let d = defaults("pf-current-owner")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "shared")
        let b = store.upsertComputer(name: "B", host: "10.0.0.2", port: 2, token: "shared")
        let c = store.upsertComputer(name: "C", host: "10.0.0.3", port: 3, token: "only-c")
        XCTAssertEqual(store.computers.count, 3)
        let oldCurrent = KeychainToken.get("current")
        defer { KeychainToken.delete(a.uuidString); KeychainToken.delete(b.uuidString); KeychainToken.delete(c.uuidString)
                if let oldCurrent { KeychainToken.set(oldCurrent, for: "current") } else { KeychainToken.delete("current") } }
        _ = KeychainToken.set("shared", for: "current")
        XCTAssertTrue(store.deleteComputer(id: b))
        XCTAssertEqual(KeychainToken.get("current"), "shared", "A 还在用同一个令牌: current 不能清")
        _ = KeychainToken.set("only-c", for: "current")
        XCTAssertTrue(store.deleteComputer(id: c))
        XCTAssertNil(KeychainToken.get("current"), "独占该令牌的电脑被删: current 一并清")
        XCTAssertEqual(KeychainToken.get(a.uuidString), "shared")
    }

    // 阻断 1: 清空令牌时 Keychain 删除失败 → 墓碑兜底, 重启后旧令牌不复活 (仍为空); 之后删除成功时旧项被清掉。
    func testClearedTokenSurvivesKeychainDeleteFailure() {
        let d = defaults("pf-clear-delete-fail")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-old")
        defer { KeychainToken.faultDelete = nil; KeychainToken.delete(a.uuidString) }
        KeychainToken.faultDelete = { $0.hasPrefix(a.uuidString) ? false : nil }          // 删这台的凭证失败
        store.updateComputerConnection(id: a, host: "10.9.9.9", port: 1, token: "")
        XCTAssertFalse(store.hasUnsavedChanges, "保存本身成功")
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-old", "旧项确实没删掉")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "", "墓碑: 加载时忽略残留的旧项")
        KeychainToken.faultDelete = nil
        _ = store.upsertComputer(name: "B", host: "10.0.0.5", port: 5, token: "")                     // 下一次保存成功: 再试删除
        XCTAssertNil(KeychainToken.get(a.uuidString), "之后删除成功, 旧项清掉")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "")
    }

    // 阻断 2: Keychain 暂时读不出来 (≠ 不存在) 不能被当成「用户清空」: 保存时不删凭证, 之后恢复读取令牌回来。
    func testUnreadableKeychainIsNotTreatedAsUserClear() {
        let d = defaults("pf-unreadable")
        let first = LayoutStore(defaults: d)
        let a = first.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.delete(a.uuidString) }
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }   // errSecInteractionNotAllowed: 设备锁定等
        let locked = LayoutStore(defaults: d)                                      // 初始化里的 persist() 照常跑
        XCTAssertEqual(locked.computer(a)?.token, "", "令牌暂时未知")
        XCTAssertFalse(locked.hasUnsavedChanges)
        _ = locked.upsertComputer(name: "B", host: "10.0.0.6", port: 6, token: "tok-B")  // 又一次保存
        KeychainToken.faultRead = nil
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-A", "没有被当成用户清空而删掉")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A", "读取恢复后令牌回来")
        defer { KeychainToken.delete(locked.computers.last!.id.uuidString) }
    }

    // 阻断 1: 墓碑与主存档按字节哈希配对 —— 不匹配当前主存档的墓碑记录一律忽略 (两个方向的错配都不会发生)。
    func testTombstoneIsPairedWithMainSaveBytes() {
        let d = defaults("pf-tombstone-pairing")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-old")
        defer { KeychainToken.delete(a.uuidString) }
        store.updateComputerConnection(id: a, host: "10.0.0.1", port: 1, token: "")              // 清空: 新主存档 M2 + 墓碑 {a}
        let m2 = d.data(forKey: "sidekey.app.v5")!
        XCTAssertEqual(LayoutStore.tombstones(for: m2, in: d), [a], "墓碑与 M2 配对")
        let tombstoneKey = LayoutStore.clearedTokensKey
        let savedTombstone = d.array(forKey: tombstoneKey)
        store.updateComputerConnection(id: a, host: "10.0.0.1", port: 1, token: "tok-new")        // 重新配对: 新主存档 M3, 墓碑收敛成空
        let m3 = d.data(forKey: "sidekey.app.v5")!
        XCTAssertNotEqual(m2, m3)
        // 模拟「新主存档 + 旧墓碑」的错配状态 (旧记录是配 M2 的): 对 M3 不生效, 新令牌不会被忽略 / 删掉
        d.set(savedTombstone, forKey: tombstoneKey)
        XCTAssertEqual(LayoutStore.tombstones(for: m3, in: d), [], "旧墓碑不匹配新主存档: 忽略")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-new", "新令牌不被旧墓碑忽略")
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-new")
    }

    // 阻断 2: 启动时第一次读失败、之后恢复可读 —— 初始化保存前会重读并填回令牌, 不建墓碑、不删凭证。
    func testReadFailsOnceThenRecoversDuringLaunchKeepsToken() {
        let d = defaults("pf-read-once-fail")
        let a = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.delete(a.uuidString) }
        var calls = 0
        KeychainToken.faultRead = { acct in
            guard acct.hasPrefix(a.uuidString) else { return nil }
            calls += 1; return calls == 1 ? .failed(-25308) : nil           // 第一次失败, 之后走真实读取
        }
        let store = LayoutStore(defaults: d)
        XCTAssertEqual(store.computer(a)?.token, "tok-A", "初始化保存前重读, 令牌填回")
        XCTAssertFalse(store.isTokenUnknown(a))
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-A", "凭证没被删")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A")
    }

    // 阻断 2: 持续读不出来期间用户明确清空令牌 → 仍然算「清空」(三种意图: 保留未知 / 设置新令牌 / 清空), 读取恢复后重启不复活。
    func testUserClearWhileUnreadableIsHonored() {
        let d = defaults("pf-clear-while-unreadable")
        let a = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.faultDelete = nil; KeychainToken.delete(a.uuidString) }
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }
        KeychainToken.faultDelete = { $0.hasPrefix(a.uuidString) ? false : nil }
        let locked = LayoutStore(defaults: d)
        XCTAssertTrue(locked.isTokenUnknown(a))
        locked.updateComputerConnection(id: a, host: "10.9.9.9", port: 1, token: "")             // 用户明确清空
        XCTAssertFalse(locked.isTokenUnknown(a))
        KeychainToken.faultRead = nil; KeychainToken.faultDelete = nil
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "", "读取恢复后重启: 清空被尊重, 旧令牌不复活")
    }

    // 重要: 令牌未知时同一进程内可恢复 (重读), 且未知期间不当作「没有令牌」。
    func testUnreadableTokenRecoversInSessionAfterRetry() {
        let d = defaults("pf-recover-in-session")
        let a = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.delete(a.uuidString) }
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }
        let store = LayoutStore(defaults: d)
        XCTAssertTrue(store.isTokenUnknown(a)); XCTAssertEqual(store.unreadableTokenCount, 1)
        store.retryUnreadableTokens()
        XCTAssertTrue(store.isTokenUnknown(a), "仍读不出来: 保持未知")
        KeychainToken.faultRead = nil                                              // 解锁
        store.retryUnreadableTokens()
        XCTAssertFalse(store.isTokenUnknown(a)); XCTAssertEqual(store.unreadableTokenCount, 0)
        XCTAssertEqual(store.computer(a)?.token, "tok-A", "同一进程内令牌回来")
    }

    // 阻断 1: 令牌未知时只改名称 (令牌框没动 = 保留) 不能当成「明确清空」去删凭证; 表单打开期间令牌已被重读恢复, 保存也不覆盖。
    func testRenameWhileTokenUnknownKeepsCredential() {
        let d = defaults("pf-keep-unknown")
        let a = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.deleteAll(id: a.uuidString) }
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }
        let store = LayoutStore(defaults: d)
        XCTAssertTrue(store.isTokenUnknown(a))
        XCTAssertTrue(store.updateComputer(id: a, name: "改名", host: "10.0.0.1", port: 1, tokenEdit: .keep, fingerprint: ""))
        KeychainToken.faultRead = nil
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-A", "凭证没被删")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A")
        // 表单打开期间令牌被重读恢复: .keep 保留 store 当前值
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }
        let s2 = LayoutStore(defaults: d)
        KeychainToken.faultRead = nil
        s2.retryUnreadableTokens()
        XCTAssertEqual(s2.computer(a)?.token, "tok-A")
        XCTAssertTrue(s2.updateComputer(id: a, name: "再改", host: "10.0.0.1", port: 1, tokenEdit: .keep, fingerprint: ""))
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A")
    }

    // 阻断 2: 令牌未知 → 填新令牌 → 超限保存被拒 → 放弃修改: 「未知」状态回来 (凭证状态在恢复点里), 之后普通改名保存不会删原凭证。
    func testDiscardRestoresUnknownTokenState() {
        let d = defaults("pf-discard-unknown")
        let a = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.deleteAll(id: a.uuidString) }
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }
        let store = LayoutStore(defaults: d)
        let saved = d.data(forKey: "sidekey.app.v5")!
        withLimit(saved.count / 2) {
            XCTAssertTrue(store.updateComputer(id: a, name: "A", host: "10.0.0.1", port: 1, tokenEdit: .set("tok-new"), fingerprint: ""))
            XCTAssertTrue(store.hasUnsavedChanges)
            XCTAssertFalse(store.isTokenUnknown(a), "草稿里已经有新令牌")
        }
        store.discardUnsavedChanges()
        XCTAssertTrue(store.isTokenUnknown(a), "放弃修改: 令牌回到「未知」")
        XCTAssertTrue(store.updateComputer(id: a, name: "改名", host: "10.0.0.1", port: 1, tokenEdit: .keep, fingerprint: ""))
        KeychainToken.faultRead = nil
        XCTAssertEqual(KeychainToken.get(a.uuidString), "tok-A", "原凭证还在")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A")
    }

    // 第十二轮阻断 3 / 第十三轮必须修 1: 令牌按**稳定引用**存 (`<id>@<rev>`)。旧主存档配旧引用 → 旧地址配旧令牌; 只有换令牌才生成新项, 提交后旧修订被回收。
    func testTokenUsesStableReference() {
        let d = defaults("pf-token-ref")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "old-host", port: 1, token: "OLD")
        defer { KeychainToken.deleteAll(id: a.uuidString) }
        let m1 = d.data(forKey: "sidekey.app.v5")!
        let r1 = LayoutStore.tokenRefs(for: m1, in: d)[a]!
        XCTAssertEqual(KeychainToken.get(LayoutStore.tokenAccount(a, rev: r1)), "OLD")
        store.renameComputer(id: a, to: "改名")                                   // 主存档变了, 令牌没变: 引用不变, 不重写
        let m1b = d.data(forKey: "sidekey.app.v5")!
        XCTAssertNotEqual(m1, m1b)
        XCTAssertEqual(LayoutStore.tokenRefs(for: m1b, in: d)[a], r1, "改名不换引用")
        store.updateComputerConnection(id: a, host: "new-host", port: 2, token: "NEW")
        let m2 = d.data(forKey: "sidekey.app.v5")!
        let r2 = LayoutStore.tokenRefs(for: m2, in: d)[a]!
        XCTAssertNotEqual(r1, r2, "换令牌才生成新项")
        XCTAssertEqual(KeychainToken.accounts(prefix: a.uuidString + "@"), [LayoutStore.tokenAccount(a, rev: r2)], "提交后旧修订被回收")
        // 模拟崩溃在「新令牌项已写、主存档未写」: 主存档仍是 M1, 旧引用的旧项 (回收前) 还在
        _ = KeychainToken.set("OLD", for: LayoutStore.tokenAccount(a, rev: r1))
        var entries = d.array(forKey: LayoutStore.clearedTokensKey) as! [[String: Any]]
        entries.append(["h": LayoutStore.blobHash(m1), "ids": [String](), "refs": [a.uuidString: r1]])
        d.set(entries, forKey: LayoutStore.clearedTokensKey)
        d.set(m1, forKey: "sidekey.app.v5")
        let crashed = LayoutStore(defaults: d)
        XCTAssertEqual(crashed.computer(a)?.host, "old-host")
        XCTAssertEqual(crashed.computer(a)?.token, "OLD", "旧主存档配旧引用: 不会出现旧地址配新令牌")
    }

    // 第十三轮必须修 1: 令牌未知期间, 保存别的数据 (主存档变了) 不丢有效令牌、不退回旧镜像。
    func testUnknownTokenSurvivesUnrelatedSavesAndStaleMirror() {
        let d = defaults("pf-unknown-saves")
        let a = LayoutStore(defaults: d).upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-A")
        defer { KeychainToken.faultRead = nil; KeychainToken.deleteAll(id: a.uuidString) }
        KeychainToken.set("stale-mirror", for: a.uuidString)                          // 镜像是旧值
        KeychainToken.faultRead = { $0.hasPrefix(a.uuidString) ? .failed(-25308) : nil }
        let store = LayoutStore(defaults: d)
        XCTAssertTrue(store.isTokenUnknown(a))
        _ = store.addPage(); _ = store.addPage()                                       // 保存别的数据, 主存档变了两次
        store.renameComputer(id: a, to: "改名")                                        // 改名也保存
        KeychainToken.faultRead = nil
        store.retryUnreadableTokens()
        XCTAssertEqual(store.computer(a)?.token, "tok-A", "按稳定引用读回原令牌, 不退回旧镜像")
        _ = store.addPage()
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A", "再保存、重启后仍是原令牌")
        KeychainToken.delete(a.uuidString)                                              // 镜像缺失也不影响
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-A")
    }

    // 第十三轮必须修 2: 保存失败时 Keychain 一点不变 —— 超限的新配对被拒, 放弃、重启后不留孤儿凭证项。
    func testRejectedPairingLeavesNoKeychainItems() {
        let d = defaults("pf-reject-pair")
        let store = LayoutStore(defaults: d)
        let saved = d.data(forKey: "sidekey.app.v5")!
        var newID: UUID!
        withLimit(saved.count + 10) { newID = store.upsertComputer(name: String(repeating: "N", count: 300), host: "9.9.9.9", port: 1, token: "tok-new") }
        defer { KeychainToken.deleteAll(id: newID.uuidString) }
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(KeychainToken.accounts(prefix: newID.uuidString), [], "保存失败: 一个凭证项也没写")
        store.discardUnsavedChanges()
        _ = LayoutStore(defaults: d)
        XCTAssertEqual(KeychainToken.accounts(prefix: newID.uuidString), [])
    }

    // Keychain 写失败 → 该电脑改用明文兜底 (不再循环重写), 重启后令牌仍在; 没有残留的新项。
    func testKeychainWriteFailureFallsBackToPlaintextOnce() {
        let d = defaults("pf-set-fail")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-1")
        defer { KeychainToken.faultSet = nil; KeychainToken.deleteAll(id: a.uuidString) }
        KeychainToken.faultSet = { $0.hasPrefix(a.uuidString + "@") ? false : nil }
        store.updateComputerConnection(id: a, host: "10.0.0.1", port: 1, token: "tok-2")
        XCTAssertFalse(store.hasUnsavedChanges, "兜底后照常提交")
        XCTAssertEqual(LayoutStore(defaults: d).computer(a)?.token, "tok-2", "明文兜底, 重启后是新令牌")
    }

    // 第十三轮必须修 4: Keychain 枚举失败 ≠ 没有账户, 回收任务保留, 恢复后补做。
    func testEnumerationFailureKeepsCleanupTask() {
        let d = defaults("pf-enum-fail")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-1")
        defer { KeychainToken.faultAccounts = nil; KeychainToken.deleteAll(id: a.uuidString) }
        KeychainToken.faultAccounts = { _ in .some(nil) }                              // 枚举失败
        store.updateComputerConnection(id: a, host: "10.0.0.1", port: 1, token: "tok-2")
        KeychainToken.faultAccounts = nil
        XCTAssertEqual(KeychainToken.accounts(prefix: a.uuidString + "@")?.count, 2, "枚举失败时没清: 旧修订还在")
        XCTAssertNotNil(d.stringArray(forKey: LayoutStore.revCleanupKey), "回收任务保留")
        _ = LayoutStore(defaults: d)                                                    // 启动时补做
        XCTAssertEqual(KeychainToken.accounts(prefix: a.uuidString + "@")?.count, 1)
        XCTAssertNil(d.stringArray(forKey: LayoutStore.revCleanupKey))
    }

    // 需求侧抽查小问题: 回收队列在提交后、回收开始之前就已落盘 —— 回收中途被关闭, 下次启动仍能删掉旧修订。
    func testRevCleanupQueuePersistedBeforeCleanupRuns() {
        let d = defaults("pf-rev-queue")
        let store = LayoutStore(defaults: d)
        let a = store.upsertComputer(name: "A", host: "10.0.0.1", port: 1, token: "tok-1")
        let oldAcct = LayoutStore.tokenAccount(a, rev: LayoutStore.tokenRefs(for: d.data(forKey: "sidekey.app.v5")!, in: d)[a]!)
        var queuedAtFirstDelete: [String]?
        defer { KeychainToken.faultDelete = nil; KeychainToken.deleteAll(id: a.uuidString) }
        KeychainToken.faultDelete = { acct in                     // 回收删第一个旧修订的那一刻 = 「被关闭」的时间点: 看此时队列是否已在磁盘上, 并让删除失败
            guard acct == oldAcct else { return nil }
            if queuedAtFirstDelete == nil { queuedAtFirstDelete = d.stringArray(forKey: LayoutStore.revCleanupKey) ?? [] }
            return false
        }
        store.updateComputerConnection(id: a, host: "10.0.0.1", port: 1, token: "tok-2")
        XCTAssertEqual(queuedAtFirstDelete, [a.uuidString], "回收开始前队列已落盘")
        KeychainToken.faultDelete = nil
        XCTAssertEqual(KeychainToken.accounts(prefix: a.uuidString + "@")?.count, 2)
        let relaunched = LayoutStore(defaults: d)                                       // 重启按队列补做
        XCTAssertEqual(KeychainToken.accounts(prefix: a.uuidString + "@")?.count, 1)
        XCTAssertEqual(relaunched.computer(a)?.token, "tok-2")
    }

    func testParseFailuresNeverOverwrite() {
        let good = save()
        var invalidTail = good; invalidTail.append(contentsOf: Data(" garbage".utf8))
        var bom = Data([0xEF, 0xBB, 0xBF]); bom.append(good)
        let truncated = good.prefix(good.count / 2)
        let cases: [(String, Data)] = [
            ("truncated", Data(truncated)),
            ("trailing-garbage", invalidTail),
            ("utf8-bom", bom),
            ("empty-object", Data("{}".utf8)),
            ("array-root", Data("[1,2,3]".utf8)),
            ("not-json", Data("hello".utf8)),
            ("empty-data", Data()),
            ("dup-top-level", save(extraTopLevel: #""builtinVersion":1,"#)),                       // builtinVersion 出现两次
            ("dup-in-unknown-payload", save(unknownPayload: #"{"x":1,"x":2}"#)),
            ("dup-nested-unknown", save(unknownPayload: #"{"a":{"b":1,"b":2}}"#)),
            ("dup-kind", save(unknownPayload: #"{"ok":true}"#).replacingBytes(#""kind":"future""#, with: #""kind":"future","kind":"normal""#)),
            ("lone-surrogate-in-label", save(label: #"\ud800"#)),
            ("lone-low-surrogate", save(label: #"\udc00"#)),
            ("deep-nesting", save(unknownPayload: String(repeating: "[", count: 600) + String(repeating: "]", count: 600))),
        ]
        for (name, raw) in cases { assertRecoversWithoutOverwriting(raw, name) }
    }

    func testInvalidUTF8AtDifferentPositionsNeverOverwrites() {
        let good = save(unknownPayload: #"{"s":"abc"}"#, label: "LAB")
        for (name, needle) in [("in-unknown-payload", #""s":"abc"#), ("in-label", #""label":"LAB"#), ("in-field-name", #""payload""#)] {
            var bytes = [UInt8](good)
            let n = Array(needle.utf8)
            guard let at = (0...(bytes.count - n.count)).first(where: { Array(bytes[$0..<($0 + n.count)]) == n }) else { return XCTFail(name) }
            bytes[at + n.count - 1] = 0xFF
            assertRecoversWithoutOverwriting(Data(bytes), "utf8-" + name)
        }
    }

    // 走完整 LayoutStore 流程的「过大 / 节点过多」: 把上限临时调小 (默认 16 MB / 200 万节点太慢), 逻辑相同。
    func testOversizedSaveNeverOverwrites() {
        let oldBytes = JSONParser.maxBytes, oldNodes = JSONParser.maxNodes
        defer { JSONParser.maxBytes = oldBytes; JSONParser.maxNodes = oldNodes }
        let valid = save()
        JSONParser.maxBytes = valid.count - 1                                   // 合法但比上限大 1 字节
        assertRecoversWithoutOverwriting(valid, "oversized", beforeResolve: { JSONParser.maxBytes = oldBytes })
        JSONParser.maxBytes = oldBytes
        JSONParser.maxNodes = 5                                                  // 节点数远超上限
        assertRecoversWithoutOverwriting(valid, "too-many-nodes", beforeResolve: { JSONParser.maxNodes = oldNodes })
    }

    // MARK: 解析器边界 (注入较小的上限)
    func testParserNodeAndSizeLimits() {
        let arr = "[" + (0..<100).map(String.init).joined(separator: ",") + "]"
        XCTAssertNoThrow(try JSONParser.parse(Data(arr.utf8), maxNodes: 101))
        XCTAssertThrowsError(try JSONParser.parse(Data(arr.utf8), maxNodes: 100), "节点数超限 (101 个节点)")
        XCTAssertThrowsError(try JSONParser.parse(Data(arr.utf8), maxBytes: 10), "大小超限")
        let ok = String(repeating: "[", count: 512) + String(repeating: "]", count: 512)
        XCTAssertNoThrow(try JSONParser.parse(Data(ok.utf8)), "深度恰好在上限内")
        let tooDeep = String(repeating: "[", count: 513) + String(repeating: "]", count: 513)
        XCTAssertThrowsError(try JSONParser.parse(Data(tooDeep.utf8)), "深度超限")
    }

    // MARK: 数字
    func testNumberGrammarAndExactPreservation() throws {
        let valid = ["0", "-0", "-0.0", "0.0", "1", "-1", "10", "1.5", "-1.5e10", "1E+5", "1e-7", "0e0", "0.5E-3",
                     "123456789012345678901234567890", "-123456789012345678901234567890",
                     "0.00000000000000000000000000000001", "18446744073709551615", "-9223372036854775808",
                     "9223372036854775807", "1.7976931348623157e309", "4.9e-325"]
        for n in valid {
            let tree = try JSONParser.parse(Data(#"{"n":\#(n)}"#.utf8))
            XCTAssertTrue(tree.serialized().contains(n), "\(n) 必须原样保留: \(tree.serialized())")
        }
        for bad in ["+1", ".5", "1.", "01", "00", "-", "--1", "0x10", "1e", "1e+", "NaN", "Infinity", "-Infinity", "1_000", "1,5"] {
            XCTAssertThrowsError(try JSONParser.parse(Data(#"{"n":\#(bad)}"#.utf8)), "\(bad) 不是合法 JSON 数字")
        }
    }

    func testAllNumbersSurviveFullStoreRoundTrip() throws {
        let numbers = ["-0", "-0.0", "1E+5", "123456789012345678901234567890", "0.00000000000000000000000000000001", "18446744073709551615", "1.7976931348623157e309"]
        let payload = "{" + numbers.enumerated().map { #""n\#($0.offset)":\#($0.element)"# }.joined(separator: ",") + "}"
        let d = defaults("pf-numbers")
        d.set(save(unknownPayload: payload), forKey: "sidekey.app.v5")
        let a = LayoutStore(defaults: d)
        XCTAssertNil(a.recovery)
        _ = a.upsertComputer(name: "触发保存", host: "1.1.1.1", port: 1, token: "")             // 迫使重新编码写回
        let text = String(decoding: d.data(forKey: "sidekey.app.v5")!, as: UTF8.self)
        for n in numbers { XCTAssertTrue(text.contains(#":\#(n)"#) || text.contains(#":\#(n),"#) || text.contains(#":\#(n)}"#), "\(n) 写回后保持原样") }
        XCTAssertNil(LayoutStore(defaults: d).recovery, "写回的存档能再次读入")
    }

    // MARK: 占位字符串和用户数据长得一样
    func testPlaceholderLookalikesInUserDataAreUntouched() throws {
        let lookalike = "@@SK-RAW-00000000-0000-0000-0000-000000000000@@"
        let d = defaults("pf-placeholder")
        d.set(save(unknownPayload: #"{"text":"\#(lookalike)","arr":["\#(lookalike)"]}"#, label: lookalike), forKey: "sidekey.app.v5")
        let a = LayoutStore(defaults: d)
        XCTAssertNil(a.recovery)
        _ = a.upsertComputer(name: "X", host: "1.1.1.1", port: 1, token: "")
        let raw = String(decoding: d.data(forKey: "sidekey.app.v5")!, as: UTF8.self)
        XCTAssertEqual(raw.components(separatedBy: lookalike).count - 1, 3, "三处长得像占位符的用户数据都原样保留 (label + payload 两处)")
        let tree = try JSONParser.parse(d.data(forKey: "sidekey.app.v5")!)
        XCTAssertTrue(tree.serialized().contains(lookalike))
        // 真正的占位符不会泄漏进存档
        XCTAssertFalse(raw.contains("@@SK-RAW-") && raw.range(of: #"@@SK-RAW-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}@@"#, options: .regularExpression).map { String(raw[$0]) != lookalike } ?? false,
                       "写出的存档里不能残留本次编码用的占位符")
    }

    // MARK: 历史编码器生成的真实存档: 来回读写一致
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: PersistenceFidelityTests.self).url(forResource: name, withExtension: "json"), "找不到夹具 \(name)")
        return try Data(contentsOf: url)
    }

    /// 去掉新版才有的 Mode.kind 后, 两棵树应完全相同。
    private func normalized(_ tree: JSONValue) -> JSONValue {
        guard case .object(var root) = tree, case .array(var cs)? = root["computers"] else { return tree }
        for i in cs.indices {
            guard case .object(var c) = cs[i], case .array(var ms)? = c["modes"] else { continue }
            for j in ms.indices { if case .object(var m) = ms[j] { m["kind"] = nil; ms[j] = .object(m) } }
            c["modes"] = .array(ms); cs[i] = .object(c)
        }
        root["computers"] = .array(cs)
        return .object(root)
    }

    func testHistoricalSavesRoundTripExactly() throws {
        for name in ["v1.0-custom-save", "v98af158-codexmicro-save"] {
            let raw = try fixture(name)
            let p = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: raw)
            XCTAssertTrue(LayoutStore.isStructurallyValid(p), name)
            let out = try SidekeyJSON.encode(p)
            XCTAssertEqual(normalized(try JSONParser.parse(out)), normalized(try JSONParser.parse(raw)), "\(name): 读后再写, 数据与原档一致 (除新增的 Mode.kind)")
            // 幂等: 再读再写, 内容完全相同 (JSONEncoder 的对象键顺序不固定, 所以比较解析后的树, 不比字节)
            let p2 = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: out)
            XCTAssertEqual(try JSONParser.parse(try SidekeyJSON.encode(p2)), try JSONParser.parse(out), "\(name): 第二轮读写内容不变")
            // 完整 LayoutStore 流程: 不进恢复页
            let d = defaults("pf-hist-" + name)
            d.set(raw, forKey: "sidekey.app.v5")
            let store = LayoutStore(defaults: d)
            XCTAssertNil(store.recovery, name)
            XCTAssertTrue(LayoutStore.corruptBackupKeys(in: d).isEmpty, name)
        }
    }

    func testCodexMicroSaveKeepsWindowAndAgentSlotKeys() throws {
        let p = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: try fixture("v98af158-codexmicro-save"))
        let keys = p.computers.flatMap(\.modes).flatMap(\.layers).flatMap(\.keys)
        XCTAssertEqual(keys.filter { $0.kind == .agentSlot }.count, 6, "6 个状态槽都在")
        XCTAssertTrue(keys.filter { $0.kind == .agentSlot }.allSatisfy { $0.slot != nil })
        XCTAssertFalse(keys.contains { $0.kind == .unknown }, "现有类型一个也不能被当成未知键")
    }
}

private extension Data {
    func replacingBytes(_ a: String, with b: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: a, with: b).utf8)
    }
}
