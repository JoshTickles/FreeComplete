import Foundation

/// Local diagnostics: one line per decision (field read, eligibility, generation,
/// display, acceptance) in ~/Library/Logs/FreeComplete/trace.log. Off unless the
/// `diagnostics` default is set. Typed-context tails are shortened, but generated
/// suggestions and accepted text can appear in full. This is not aggregate-only data.
@MainActor
enum Trace {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FreeComplete/trace.log")
    private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "diagnostics") }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        if handle == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Start fresh above 2 MB so the log never grows without bound.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        let line = formatter.string(from: Date()) + " " + message() + "\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    /// The last characters of typed text, with newlines visible.
    static func tail(_ text: String) -> String {
        String(text.suffix(16)).replacingOccurrences(of: "\n", with: "⏎").debugDescription
    }
}
