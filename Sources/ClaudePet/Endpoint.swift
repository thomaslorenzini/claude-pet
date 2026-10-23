import Foundation

/// Where the hooks find the running pet: `<port> <pid>` in
/// `~/Library/Application Support/claude-pet/endpoint`.
///
/// The port is not fixed (the server moves on if it is taken), and the pid lets a hook check with
/// the shell builtin `kill -0` that the pet is alive before calling curl at all.
enum Endpoint {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/claude-pet", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("endpoint") }

    static func publish(port: UInt16) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            // Trailing newline: `read` in sh fails on a last line without one.
            try Data("\(port) \(getpid())\n".utf8).write(to: file, options: .atomic)
        } catch {
            NSLog("claude-pet: impossible d'écrire %@ : %@", file.path, "\(error)")
        }
    }

    /// Removes the file only if it is still ours, so quitting a duplicate never unpublishes the real pet.
    static func unpublish() {
        guard let content = try? String(contentsOf: file, encoding: .utf8),
              content.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpid())
        else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
