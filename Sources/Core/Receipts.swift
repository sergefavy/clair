import Foundation

/// Accès aux reçus d'installation des paquets `.pkg`.
public protocol ReceiptStore: Sendable {
    /// Identifiants des paquets ayant installé ce chemin.
    func owners(of path: String) -> [String]
    func packageIDs() -> [String]
    func exists(_ id: String) -> Bool
}

/// Implémentation fondée sur `/usr/sbin/pkgutil` (lecture seule).
public struct PkgutilReceipts: ReceiptStore {
    public init() {}

    private func run(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func owners(of path: String) -> [String] {
        let (status, output) = run(["--file-info", path])
        guard status == 0 else { return [] }
        return output.split(separator: "\n").compactMap { line in
            line.hasPrefix("pkgid: ") ? String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    public func packageIDs() -> [String] {
        let (status, output) = run(["--pkgs"])
        guard status == 0 else { return [] }
        return output.split(separator: "\n").map(String.init)
    }

    public func exists(_ id: String) -> Bool {
        run(["--pkg-info", id]).0 == 0
    }
}
