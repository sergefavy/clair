import Foundation

public struct Cleaner: Sendable {
    public let home: URL
    public let applicationRoots: [URL]
    public let roots: [SearchRoot]
    let systemLibrary: URL
    let receipts: any ReceiptStore
    /// Vrai si l'utilisateur peut déplacer l'élément sans droits administrateur.
    let canRemove: @Sendable (URL) -> Bool
    /// Vrai si une application portant cet identifiant est encore installée (Launch Services).
    let isInstalled: @Sendable (String) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                applicationRoots: [URL]? = nil,
                systemLibrary: URL = URL(fileURLWithPath: "/Library"),
                darwinDirectories: [URL]? = nil,
                receipts: any ReceiptStore = PkgutilReceipts(),
                canRemove: @escaping @Sendable (URL) -> Bool = { FileManager.default.isDeletableFile(atPath: $0.path) },
                isInstalled: @escaping @Sendable (String) -> Bool = { _ in false }) {
        let home = Paths.realURL(home)
        self.home = home
        self.applicationRoots = (applicationRoots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]).map(Paths.realURL)
        let darwin = darwinDirectories ?? [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap(Paths.darwinUserDirectory)
        // Racines construites à partir de chemins réels : un dossier remplacé par un lien
        // symbolique sera refusé à la validation (chemin réel différent).
        self.roots = Self.userRoots(home: home, darwinDirectories: darwin.map(Paths.realURL))
            + Self.systemRoots(library: Paths.realURL(systemLibrary))
        self.systemLibrary = Paths.realURL(systemLibrary)
        self.receipts = receipts
        self.canRemove = canRemove
        self.isInstalled = isInstalled
    }

    // MARK: - Règles générales

    static func isAppleID(_ identifier: String) -> Bool {
        identifier.lowercased().hasPrefix("com.apple.")
    }

    static func isProtectedPath(_ path: String) -> Bool {
        ["/System/", "/Library/Apple/", "/usr/", "/bin/", "/sbin/", "/private/var/db/"].contains { path.hasPrefix($0) }
    }

    /// « us.zoom » pour « us.zoom.xos » ; nil si l'identifiant a moins de trois composants.
    static func vendor(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Lettres et chiffres uniquement, sans casse ni accents.
    public static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }

    static func isWithin(_ child: String, _ parent: String) -> Bool {
        child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    // MARK: - Applications installées

    public func applications() -> [InstalledApp] {
        var result: [InstalledApp] = []
        for root in applicationRoots {
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walk {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
                if url.pathExtension.lowercased() == "app" {
                    if let app = InstalledApp(bundleAt: url) { result.append(app) }
                } else if walk.level >= 3 {
                    walk.skipDescendants()
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Plugins, panneaux, modules et apps auxiliaires installés hors de /Applications.
    /// Sert à ne pas présenter leurs réglages comme des restes.
    public func installedComponents() -> [(id: String, name: String)] {
        let folders = ["Audio/Plug-Ins/Components", "Audio/Plug-Ins/VST", "Audio/Plug-Ins/VST3", "Audio/Plug-Ins/HAL",
                       "Audio/Plug-Ins/MAS", "CoreMediaIO/Plug-Ins/DAL", "Internet Plug-Ins", "PreferencePanes",
                       "Screen Savers", "QuickLook", "Spotlight", "Input Methods", "Services", "Application Support", "Frameworks"]
        var result: [(String, String)] = []
        for library in [home.appendingPathComponent("Library"), systemLibrary] {
            for folder in folders {
                let root = library.appendingPathComponent(folder)
                guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
                var count = 0
                for case let url as URL in walk {
                    count += 1
                    if count > 50_000 { break }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                    if !url.pathExtension.isEmpty, let info = Self.propertyList(url.appendingPathComponent("Contents/Info.plist")),
                       let id = info["CFBundleIdentifier"] as? String {
                        result.append((id, (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent))
                        walk.skipDescendants()
                    } else if walk.level >= 4 {
                        walk.skipDescendants()
                    }
                }
            }
        }
        return result
    }

    // MARK: - Taille

    /// Taille logique sans suivre les liens. Le booléen indique une mesure partielle.
    public func measure(_ url: URL) -> (Int64, Bool) {
        guard let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { return (0, true) }
        if info.isSymbolicLink == true { return (0, false) }
        if info.isDirectory != true { return (Int64(info.fileSize ?? 0), false) }
        var bytes: Int64 = 0, count = 0, incomplete = false
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, errorHandler: { _, _ in
            incomplete = true; return true
        }) else { return (0, true) }
        for case let item as URL in walk {
            count += 1
            if count > 200_000 || Task.isCancelled { incomplete = true; break }
            // L'énumérateur ne suit pas les liens ; un lien n'est pas un fichier régulier.
            guard let value = try? item.resourceValues(forKeys: Set(keys)) else { incomplete = true; continue }
            if value.isRegularFile == true { bytes += Int64(value.fileSize ?? 0) }
        }
        return (bytes, incomplete)
    }
}
