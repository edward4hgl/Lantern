import Foundation
import os

/// 日志门面。Mac 上 `log stream --predicate 'subsystem == "app.lantern.slides"'` 可直接看。
enum Log {
    private static let subsystem = "app.lantern.slides"
    static let photos = Logger(subsystem: subsystem, category: "photos")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let playback = Logger(subsystem: subsystem, category: "playback")
}
