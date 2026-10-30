import Foundation

/// 按电脑分开存的显示状态: Claude Code 权限模式、思考强度 (§4.7)。
/// 存独立 key (`sidekey.perComputer.v1`), 不进 v5 主存档, 旧版 App 碰不到。
/// 迁移 (幂等): 独立 key 不存在时, 把旧的全局值复制给所有已有电脑; 旧的全局 key 保留不删 (至少留一个版本, §6.4 先备份原则)。
@MainActor
final class PerComputerStore: ObservableObject {
    struct Entry: Codable, Equatable {
        var permission: Int?     // PermissionMode.rawValue
        var effort: Int?         // EffortLevel.rawValue
        var platform: String?    // 笔记本键盘的排法 (§4.9): 电脑端 ready.platform 识别出的 mac / windows; 没识别出来为 nil
    }

    static let storeKey = "sidekey.perComputer.v1"
    static let legacyPermissionKey = "sidekey.permission.mode"
    static let legacyEffortKey = "sidekey.effort.level"

    @Published private(set) var entries: [UUID: Entry]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, computerIDs: [UUID]) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey) {
            if let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
                entries = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
            } else {
                // key 存在但读不出来: 先备份原始数据, 用默认值, **不再**从旧全局值迁移 (迁移只在 key 不存在时发生)
                LayoutStore.backUpCorrupt(data, in: defaults, prefix: Self.storeKey + ".corrupt")
                entries = [:]
            }
        } else {
            // 首次 (或存档读不出来): 从旧的全局值迁移, 复制给所有已有电脑。读不出来时原始数据留在原 key 里不动, 下次保存才覆盖。
            let perm = defaults.object(forKey: Self.legacyPermissionKey) as? Int
            let eff = defaults.object(forKey: Self.legacyEffortKey) as? Int
            var seeded: [UUID: Entry] = [:]
            if perm != nil || eff != nil {
                for id in computerIDs { seeded[id] = Entry(permission: perm, effort: eff) }
            }
            entries = seeded
            persist()
        }
    }

    func permissionRaw(for id: UUID) -> Int { entries[id]?.permission ?? PermissionMode.ask.rawValue }
    func effortRaw(for id: UUID) -> Int { entries[id]?.effort ?? EffortLevel.high.rawValue }

    func setPermission(_ raw: Int, for id: UUID) {
        var e = entries[id] ?? Entry()
        e.permission = raw
        entries[id] = e
        persist()
    }

    func setEffort(_ raw: Int, for id: UUID) {
        var e = entries[id] ?? Entry()
        e.effort = raw
        entries[id] = e
        persist()
    }

    /// 笔记本键盘的排法 (§4.9「排法跟电脑走」): 这台电脑上次识别出的排法; 从没识别出来返回 nil。
    func platform(for id: UUID) -> LaptopPlatform? { entries[id]?.platform.flatMap(LaptopPlatform.init(rawValue:)) }

    func setPlatform(_ p: LaptopPlatform, for id: UUID) {
        guard entries[id]?.platform != p.rawValue else { return }
        var e = entries[id] ?? Entry()
        e.platform = p.rawValue
        entries[id] = e
        persist()
    }

    /// 删掉已不存在的电脑的记录。
    func prune(keeping ids: [UUID]) {
        let keep = Set(ids)
        let pruned = entries.filter { keep.contains($0.key) }
        guard pruned.count != entries.count else { return }
        entries = pruned
        persist()
    }

    private func persist() {
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: Self.storeKey) }
    }
}
