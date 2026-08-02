import Foundation

final class AppLogger: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL
    private let lock = NSLock()

    init() throws {
        directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MagicMouseSwitch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        fileURL = directoryURL.appendingPathComponent("MagicMouseSwitch.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("[\(timestamp)] \(message)\n".utf8)
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            FileHandle.standardError.write(
                Data("Magic Mouse Switch logging failed: \(error)\n".utf8)
            )
        }
    }
}
