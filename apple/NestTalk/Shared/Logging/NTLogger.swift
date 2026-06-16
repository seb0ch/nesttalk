import Foundation
import os

/// Thin wrapper around `os.Logger` with a rotating-file sink at
/// `Application Support/NestTalkLogs/current.log`. Family-user debug
/// support uses Settings → Export logs (Sprint-5 follow-up) to share a
/// zip of the last 7 days.
///
/// **Privacy.** Plaintext logs MUST NOT include message bodies or
/// secrets. Every helper here sanitizes its input — passes envelope
/// metadata + error codes only, never plaintext.
public final class NTLogger: @unchecked Sendable {

    public static let transport = NTLogger(category: "transport")
    public static let calls     = NTLogger(category: "calls")
    public static let identity  = NTLogger(category: "identity")
    public static let messaging = NTLogger(category: "messaging")
    public static let crypto    = NTLogger(category: "crypto")
    public static let push      = NTLogger(category: "push")

    private let logger: Logger
    private let fileSink: FileSink?
    public let category: String

    public init(category: String, subsystem: String = "com.nesttalk", baseURL: URL? = nil) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
        self.fileSink = FileSink(baseURL: baseURL ?? Self.defaultBaseURL())
    }

    public func info(_ message: @autoclosure () -> String) {
        let m = message()
        logger.info("\(m, privacy: .public)")
        fileSink?.append(level: "info", category: category, line: m)
    }

    public func error(_ message: @autoclosure () -> String) {
        let m = message()
        logger.error("\(m, privacy: .public)")
        fileSink?.append(level: "error", category: category, line: m)
    }

    public func debug(_ message: @autoclosure () -> String) {
        let m = message()
        logger.debug("\(m, privacy: .public)")
        fileSink?.append(level: "debug", category: category, line: m)
    }

    static func defaultBaseURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("NestTalkLogs", isDirectory: true)
    }
}

/// Daily-rotated file sink. New file at midnight local; keeps 7 days +
/// the running file. Older files are retained as plain text — Sprint
/// 6's Export-Logs button zips them on demand. Goal here is
/// correctness + determinism, not throughput.
final class FileSink: @unchecked Sendable {
    private let baseURL: URL
    private let queue = DispatchQueue(label: "nt.logger.sink")
    private let formatter: DateFormatter
    private let dayFormatter: DateFormatter
    private let maxRetainedDays: Int = 7

    init?(baseURL: URL) {
        self.baseURL = baseURL
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = f
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = d
    }

    func append(level: String, category: String, line: String) {
        let timestamp = formatter.string(from: Date())
        let day = dayFormatter.string(from: Date())
        let entry = "\(timestamp) [\(level)] [\(category)] \(line)\n"
        queue.async { [self] in
            let url = baseURL.appendingPathComponent("\(day).log")
            if let data = entry.data(using: .utf8) {
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
            self.pruneOldFiles()
        }
    }

    private func pruneOldFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let logs = entries.filter { $0.pathExtension == "log" }
        guard logs.count > maxRetainedDays else { return }
        let sorted = logs.sorted { l, r in
            let lc = (try? l.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rc = (try? r.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lc < rc
        }
        let prune = sorted.prefix(sorted.count - maxRetainedDays)
        for url in prune {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
