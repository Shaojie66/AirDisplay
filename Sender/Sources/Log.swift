import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "io.github.shaojie66.airdisplay", category: "sender")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print(message)
    }
}
