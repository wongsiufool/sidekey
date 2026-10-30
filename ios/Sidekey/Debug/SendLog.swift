import Foundation

/// 发送记录 (§9 验证工具): DEBUG 构建里把每条发给电脑的消息记下来 (时间 + 内容), 用来核对「手机发了什么」。
/// 例如 T-IN-1: 鼠标 down / up 是否成对; T-IN-4: 旋转后 50 ms 内是否出现 mouse up。Release 构建是空操作。
enum SendLog {
    #if DEBUG
    struct Entry { let time: TimeInterval; let json: String }
    private static let lock = NSLock()
    private static var storage: [Entry] = []
    static var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return storage }
    static func clear() { lock.lock(); storage.removeAll(); lock.unlock() }
    static func record(_ json: String) {
        let t = ProcessInfo.processInfo.systemUptime
        lock.lock(); storage.append(Entry(time: t, json: json)); if storage.count > 2000 { storage.removeFirst(500) }; lock.unlock()
        if DebugArgs.has("--sendlog") {
            let shown = redacted(json)                    // 打印 / 写文件的那份抹掉令牌 (内存里的记录供单测核对, 不落盘)
            print(String(format: "SENT %.3f %@", t, shown))
            DebugTimeline.record("SENT \(shown)")          // --timeline 时同时写进时间线文件 (模拟器里取回方便)
        }
    }

    /// 抹掉 hello 里的配对令牌: `"token":"…"` → `"token":"<redacted>"`。
    static func redacted(_ json: String) -> String {
        json.replacingOccurrences(of: #""token"\s*:\s*"[^"]*""#, with: #""token":"<redacted>""#, options: .regularExpression)
    }
    #else
    @inline(__always) static func record(_ json: String) {}
    #endif
}
