import Foundation
import os

/// 日志同时写到系统日志和 ~/Library/Logs/AirDisplay/sender.log（方便远程排查）。
enum Log {
    private static let logger = Logger(subsystem: "io.github.shaojie66.airdisplay", category: "sender")
    private static let queue = DispatchQueue(label: "airdisplay.log")
    private static let fileHandle: FileHandle? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AirDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sender.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(timeFormat.string(from: Date())) \(message)\n"
        queue.async { fileHandle?.write(line.data(using: .utf8)!) }
    }
}
