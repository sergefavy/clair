import Foundation

/// Dossier dont les enfants directs sont examinés.
public struct SearchRoot: Sendable, Hashable {
    public let url: URL
    public let category: String
    /// Partagé entre plusieurs applications : jamais coché par défaut.
    public var shared = false
    /// Contient des définitions launchd.
    public var launchDomain: LaunchDomain?
    /// Rapports de plantage nommés « Processus-date.ips ».
    public var crashReports = false
    /// Affiché pour information, jamais supprimable (extensions système).
    public var protected = false
    /// Hors du dossier personnel : correspondances par nom moins fiables.
    public var system = false
    /// Examine aussi un niveau de sous-dossiers (« Éditeur/Application »).
    public var nested = false
    /// Accepte les identifiants du même éditeur (services et outils privilégiés).
    public var vendorMatching = false
}

enum Paths {
    /// Chemin réel (liens symboliques résolus, « /private » conservé), ou nil si absent.
    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func realURL(_ url: URL) -> URL {
        URL(fileURLWithPath: real(url.path) ?? url.standardizedFileURL.path)
    }

    /// Dossiers Darwin par utilisateur (/var/folders/…/C et …/T).
    static func darwinUserDirectory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

extension Cleaner {
    static func userRoots(home: URL, darwinDirectories: [URL]) -> [SearchRoot] {
        let lib = home.appendingPathComponent("Library")
        func r(_ relative: String, _ category: String) -> SearchRoot {
            SearchRoot(url: lib.appendingPathComponent(relative), category: category)
        }
        var support = r("Application Support", "Données"); support.nested = true
        var caches = r("Caches", "Caches"); caches.nested = true
        var logs = r("Logs", "Journaux"); logs.nested = true
        var roots = [
            support, caches, logs,
            r("Preferences", "Préférences"), r("Preferences/ByHost", "Préférences"),
            r("Containers", "Conteneurs"), r("Saved Application State", "État sauvegardé"),
            r("HTTPStorages", "Stockage web"), r("WebKit", "Stockage web"),
            r("Cookies", "Cookies"), r("Application Scripts", "Scripts"),
            r("Autosave Information", "Sauvegardes automatiques"),
            r("PreferencePanes", "Panneaux de réglages"), r("Services", "Services"),
            r("Internet Plug-Ins", "Modules"), r("Screen Savers", "Économiseurs d’écran"),
        ]
        var groups = r("Group Containers", "Groupes partagés"); groups.shared = true
        var agents = r("LaunchAgents", "Démarrage"); agents.launchDomain = .user
        var crashes = r("Logs/DiagnosticReports", "Rapports de plantage"); crashes.crashReports = true
        var crashPrefs = r("Application Support/CrashReporter", "Rapports de plantage"); crashPrefs.crashReports = true
        roots += [groups, agents, crashes, crashPrefs]
        roots += darwinDirectories.map { SearchRoot(url: $0, category: "Caches système") }
        return roots
    }

    static func systemRoots(library: URL) -> [SearchRoot] {
        func r(_ relative: String, _ category: String) -> SearchRoot {
            var root = SearchRoot(url: library.appendingPathComponent(relative), category: category)
            root.system = true
            return root
        }
        var agents = r("LaunchAgents", "Démarrage (tous les utilisateurs)"); agents.launchDomain = .user; agents.vendorMatching = true
        var daemons = r("LaunchDaemons", "Services système"); daemons.launchDomain = .system; daemons.vendorMatching = true
        var helpers = r("PrivilegedHelperTools", "Outils privilégiés"); helpers.vendorMatching = true
        var support = r("Application Support", "Données (tous les utilisateurs)"); support.nested = true
        var caches = r("Caches", "Caches (tous les utilisateurs)"); caches.nested = true
        var logs = r("Logs", "Journaux (tous les utilisateurs)"); logs.nested = true
        var sysExt = r("SystemExtensions", "Extensions système"); sysExt.protected = true
        var kext = r("Extensions", "Extensions noyau"); kext.protected = true
        return [
            support, caches, r("Preferences", "Préférences (tous les utilisateurs)"), logs,
            agents, daemons, helpers,
            r("Audio/Plug-Ins/HAL", "Pilotes audio"), r("CoreMediaIO/Plug-Ins/DAL", "Pilotes caméra"),
            r("Internet Plug-Ins", "Modules"), r("PreferencePanes", "Panneaux de réglages"),
            r("Screen Savers", "Économiseurs d’écran"), sysExt, kext,
        ]
    }
}
