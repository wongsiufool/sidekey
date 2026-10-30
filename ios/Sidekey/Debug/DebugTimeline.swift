import Foundation

/// 调试时间线 (只在 DEBUG 且带 `--timeline` 时写): 把几何变化、触摸数、跟踪器复位 / 摘除、冻结 / 解冻、按钮动作按时间顺序写进
/// `Documents/timeline.log`, 用来查「旋转后首次点击没反应」这类时序问题。Release 构建是空操作。
enum DebugTimeline {
    #if DEBUG
    private static let lock = NSLock()
    private static let enabled = DebugArgs.has("--timeline")
    static func record(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, text())
        lock.lock(); defer { lock.unlock() }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("timeline.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
    #else
    @inline(__always) static func record(_ text: @autoclosure () -> String) {}
    #endif
}
