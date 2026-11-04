import SwiftUI
import ClairCore

struct ClairApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        Window("Clair", id: "main") {
            MainView(model: model).frame(minWidth: 900, minHeight: 600).tint(accent)
        }
        .defaultSize(width: 1100, height: 740)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// `Clair --analyser /Applications/X.app` ou `Clair --restes` : rapport en lecture seule dans le terminal.
func runCommandLine(_ arguments: [String]) {
    let cleaner = Cleaner(isInstalled: Model.isInstalled)
    func line(_ c: Candidate) -> String {
        "\(c.recommended ? "[x]" : c.removable ? "[ ]" : "[-]") \(c.evidence.rawValue) · \(formatSize(c.bytes))\(c.requiresAdmin ? " · admin" : "")\n    \(c.url.path)\n    \(c.reason)"
    }
    if arguments.first == "--restes" {
        let result = cleaner.scanOrphans(installed: cleaner.applications())
        for group in result.groups {
            print("\n■ \(group.bundleID) — \(formatSize(group.bytes))\(group.sameVendorAs.map { " (même éditeur que \($0))" } ?? "")")
            group.candidates.forEach { print(line($0)) }
        }
        result.warnings.forEach { print("! " + $0) }
    } else if arguments.count >= 2, let app = InstalledApp(bundleAt: URL(fileURLWithPath: arguments[1])) {
        let scan = cleaner.scan(app)
        print("\(scan.app.name) — \(scan.app.bundleID)\nComposants : \(scan.app.componentIDs.sorted().joined(separator: ", "))")
        scan.candidates.forEach { print(line($0)) }
        scan.warnings.forEach { print("! " + $0) }
    } else {
        print("Usage : Clair --analyser /Applications/Nom.app | Clair --restes")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--analyser" || arguments.first == "--restes" {
    runCommandLine(arguments)
} else {
    ClairApp.main()
}
