import Foundation

/// Identifiant de Clair lui-même : jamais proposé à la suppression.
public let clairBundleID = "fr.sergefavy.clair"

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    /// Noms internes lus dans le paquet (exécutable, composants). Indices plus faibles que `name`.
    public var discoveredNames: Set<String> = []
    /// Identifiants des composants embarqués (XPC, helpers, extensions, services launchd).
    public var componentIDs: Set<String> = []

    public init(url: URL, name: String, bundleID: String) {
        self.url = url.standardizedFileURL
        self.name = name
        self.bundleID = bundleID
    }

    /// Lit le nom et l'identifiant d'un paquet `.app`.
    public init?(bundleAt url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        self.init(url: url, name: name, bundleID: bundle.bundleIdentifier ?? "")
    }

    /// Les deux premiers composants de l'identifiant (« us.zoom » pour « us.zoom.xos »).
    public var vendorPrefix: String? { Cleaner.vendor(of: bundleID) }

    /// Applications Apple, système, intégrées à une autre application, ou Clair lui-même.
    public var isProtected: Bool {
        Cleaner.isProtectedPath(url.path) || Cleaner.isAppleID(bundleID) || bundleID.lowercased() == clairBundleID
            || url.deletingLastPathComponent().path.lowercased().contains(".app")
    }
}

/// Niveau de confiance d'une correspondance. Seuls les niveaux forts sont cochés par défaut.
public enum Evidence: String, Sendable {
    case application = "Application"
    case identifier = "Identifiant exact"
    case component = "Composant de l’application"
    case name = "Nom de l’application"
    case possible = "À vérifier"
    case protected = "Protégé"

    public var isStrong: Bool { self == .application || self == .identifier || self == .component || self == .name }
}

public enum CandidateKind: Sendable, Hashable {
    case app
    case file
    /// Reçu d'installation `pkgutil` (oublié avec `pkgutil --forget`).
    case receipt(String)
}

public enum LaunchDomain: Sendable, Hashable { case user, system }

/// Empreinte d'un fichier au moment de l'analyse : on refuse d'agir s'il a changé.
public struct Stamp: Equatable, Sendable, Hashable {
    let inode: UInt64
    let device: UInt64
    let modified: Date
    public static func read(_ url: URL) throws -> Stamp {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return Stamp(inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                     device: (a[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                     modified: a[.modificationDate] as? Date ?? .distantPast)
    }
}

public struct Candidate: Identifiable, Sendable, Hashable {
    public var id: String {
        if case .receipt(let pkg) = kind { return "receipt:" + pkg }
        return url.path
    }
    public let url: URL
    public let kind: CandidateKind
    public let category: String
    public let evidence: Evidence
    public let reason: String
    public let bytes: Int64
    public let sizeIncomplete: Bool
    public let stamp: Stamp?
    /// Le dossier parent n'est pas modifiable par l'utilisateur : mot de passe administrateur requis.
    public let requiresAdmin: Bool
    /// Service launchd à arrêter avant de déplacer le fichier.
    public let launchDomain: LaunchDomain?

    public init(url: URL, kind: CandidateKind, category: String, evidence: Evidence, reason: String, bytes: Int64,
                sizeIncomplete: Bool, stamp: Stamp?, requiresAdmin: Bool, launchDomain: LaunchDomain?) {
        self.url = url; self.kind = kind; self.category = category; self.evidence = evidence; self.reason = reason
        self.bytes = bytes; self.sizeIncomplete = sizeIncomplete; self.stamp = stamp
        self.requiresAdmin = requiresAdmin; self.launchDomain = launchDomain
    }

    public var removable: Bool { evidence != .protected }
    public var recommended: Bool { removable && evidence.isStrong }
}

public struct AppScan: Sendable {
    public let app: InstalledApp
    public let candidates: [Candidate]
    public let warnings: [String]
}

/// Restes d'une application qui n'est plus installée, regroupés par identifiant.
public struct OrphanGroup: Identifiable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let candidates: [Candidate]
    /// Une application installée partage le même éditeur : prudence.
    public let sameVendorAs: String?
    public var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

public struct OrphanScan: Sendable {
    public let groups: [OrphanGroup]
    public let warnings: [String]
}

public enum CleanerError: LocalizedError, Equatable {
    case unsafe(String), changed(String), cancelled, failed(String)
    public var errorDescription: String? {
        switch self {
        case .unsafe(let path): return "Chemin protégé ou hors des emplacements autorisés : \(path)"
        case .changed(let path): return "Élément modifié depuis l’analyse, relance l’analyse : \(path)"
        case .cancelled: return "Authentification annulée."
        case .failed(let message): return message
        }
    }
}

public struct RemovalOutcome: Sendable {
    /// Identifiants des candidats vérifiés comme retirés.
    public let removed: Set<String>
    public let failures: [String]
    public let cancelled: Bool
    public let log: String
}
