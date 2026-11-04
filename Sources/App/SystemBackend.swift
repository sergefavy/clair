import Foundation
import ClairCore

/// Opérations réelles : Corbeille, Finder (avec mot de passe si besoin), commandes administrateur.
struct SystemBackend: RemovalBackend {
    func trash(_ url: URL) async throws {
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        catch {
            // Les conteneurs d'apps sont protégés par macOS : sans « Accès complet au disque »,
            // même le Finder échoue (Cocoa 513 / OSStatus -5000). Inutile de le lui confier.
            let parent = url.deletingLastPathComponent().lastPathComponent
            let inContainers = ["Containers", "Group Containers"].contains(parent)
            if url.pathExtension.lowercased() != "app",
               Self.has(error, NSPOSIXErrorDomain, Int(EPERM)) || (inContainers && Self.isPermissionError(error)) {
                throw CleanerError.needsFullDiskAccess(url.path)
            }
            throw error
        }
    }

    /// « Accès complet au disque » : seul un processus autorisé peut lire la base TCC de l'utilisateur.
    static func hasFullDiskAccess() -> Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: tcc) else { return false }
        try? handle.close()
        return true
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        has(error, NSCocoaErrorDomain, CocoaError.fileWriteNoPermission.rawValue)
            || has(error, NSOSStatusErrorDomain, -5000)
            || has(error, NSPOSIXErrorDomain, Int(EACCES))
    }

    private static func has(_ error: Error, _ domain: String, _ code: Int) -> Bool {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == domain, e.code == code { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Le Finder demande lui-même le mot de passe et possède la permission « Gestion des apps ».
    /// Les chemins sont transmis en arguments, jamais insérés dans le script.
    func trashWithFinder(_ urls: [URL]) async throws {
        try await Self.osascript([
            "on run argv",
            "set targets to {}",
            "repeat with p in argv",
            "set end of targets to ((POSIX file (contents of p)) as alias)",
            "end repeat",
            "tell application \"Finder\" to delete targets",
            "end run",
        ], arguments: urls.map(\.path))
    }

    /// Une seule fenêtre d'authentification macOS pour toutes les commandes.
    func runAsAdmin(_ commands: [[String]]) async throws {
        let script = commands.map { $0.map(Self.quote).joined(separator: " ") + " || true" }.joined(separator: "; ")
        try await Self.osascript([
            "on run argv",
            "do shell script (item 1 of argv) with administrator privileges",
            "end run",
        ], arguments: [script])
    }

    func unloadUserService(_ plist: URL) async {
        _ = try? await Self.run("/bin/launchctl", ["bootout", "gui/\(getuid())", plist.path])
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func osascript(_ lines: [String], arguments: [String]) async throws {
        let (status, error) = try await run("/usr/bin/osascript", lines.flatMap { ["-e", $0] } + arguments)
        guard status != 0 else { return }
        if error.contains("-128") { throw CleanerError.cancelled }
        if error.contains("-1743") {
            throw CleanerError.failed("Clair n’est pas autorisé à piloter le Finder. Active-le dans Réglages Système › Confidentialité et sécurité › Automatisation, puis réessaie.")
        }
        throw CleanerError.failed("macOS a refusé l’opération : " + error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
