// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

@main
struct BoiteAOutilsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("menuBarMonitor") private var menuBarMonitor = true
    @StateObject private var monitor = SystemMonitor()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .frame(minWidth: 1020, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("À propos de Boîte à outils") { AppDelegate.showAbout() }
            }
        }

        MenuBarExtra(isInserted: $menuBarMonitor) {
            MenuBarPanel(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["menuBarMonitor": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClipboardHistory.shared.start()
        if WindowSnapper.shared.enabled { WindowSnapper.shared.register() }
        SecurityMonitor.shared.configure()
    }

    static func showAbout() {
        var credits = "Entretien, diagnostic et personnalisation du Mac.\nAucune donnée n'est envoyée : tout est analysé localement.\n\nCréé par \(Author.name) — github.com/\(Author.name)\nLogiciel libre sous licence GPL-3.0-or-later."
        if let url = Bundle.main.url(forResource: "Licences", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            credits += "\n\n" + text
        }
        let attributed = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: attributed])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Avec le moniteur de barre des menus, l'app reste active après la fermeture de la fenêtre.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "menuBarMonitor")
    }
}

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case dashboard, permissions, cleaner, privacy, space, largeFiles, duplicates, devPurge
    case uninstaller, orphans, startup, processes, maintenance, tweaks, updates, history
    case toggles, customize, windows, clipboard, network
    case battery, ports, sensors, disks, displays, security, utilities
    case myApps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Tableau de bord"
        case .permissions: "Autorisations"
        case .cleaner: "Nettoyage système"
        case .privacy: "Confidentialité"
        case .space: "Espace disque"
        case .largeFiles: "Gros fichiers"
        case .duplicates: "Doublons"
        case .devPurge: "Projets de dev"
        case .uninstaller: "Désinstallateur"
        case .orphans: "Restes orphelins"
        case .startup: "Démarrage"
        case .processes: "Processus"
        case .maintenance: "Maintenance"
        case .tweaks: "Réglages cachés"
        case .updates: "Mises à jour"
        case .history: "Historique"
        case .toggles: "Interrupteurs"
        case .customize: "Personnalisation"
        case .windows: "Fenêtres"
        case .clipboard: "Presse-papiers"
        case .network: "Réseau"
        case .battery: "Batterie"
        case .ports: "Câbles & ports"
        case .sensors: "Capteurs"
        case .disks: "Disques"
        case .displays: "Écrans"
        case .security: "Sécurité"
        case .utilities: "Utilitaires"
        case .myApps: "Mes logiciels"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .permissions: "lock.shield.fill"
        case .cleaner: "sparkles"
        case .privacy: "hand.raised.fill"
        case .space: "chart.pie.fill"
        case .largeFiles: "doc.zipper"
        case .duplicates: "square.on.square"
        case .devPurge: "curlybraces.square.fill"
        case .uninstaller: "xmark.app.fill"
        case .orphans: "puzzlepiece.extension.fill"
        case .startup: "power"
        case .processes: "cpu"
        case .maintenance: "wrench.and.screwdriver.fill"
        case .tweaks: "slider.horizontal.3"
        case .updates: "arrow.down.circle.fill"
        case .history: "clock.arrow.circlepath"
        case .toggles: "switch.2"
        case .customize: "paintbrush.fill"
        case .windows: "rectangle.split.2x2.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .network: "network"
        case .battery: "battery.100.bolt"
        case .ports: "cable.connector"
        case .sensors: "thermometer.medium"
        case .disks: "internaldrive.fill"
        case .displays: "display.2"
        case .security: "shield.lefthalf.filled"
        case .utilities: "hammer.fill"
        case .myApps: "square.grid.2x2.fill"
        }
    }

    var color: Color {
        switch self {
        case .dashboard: .blue
        case .permissions: .green
        case .cleaner: .pink
        case .privacy: .blue
        case .space: .indigo
        case .largeFiles: .orange
        case .duplicates: .teal
        case .devPurge: .mint
        case .uninstaller: .red
        case .orphans: .brown
        case .startup: .green
        case .processes: .purple
        case .maintenance: .gray
        case .tweaks: .yellow
        case .updates: .cyan
        case .history: .secondary
        case .toggles: .orange
        case .customize: .pink
        case .windows: .indigo
        case .clipboard: .teal
        case .network: .blue
        case .battery: .green
        case .ports: .orange
        case .sensors: .red
        case .disks: .indigo
        case .displays: .cyan
        case .security: .red
        case .utilities: .brown
        case .myApps: .purple
        }
    }
}

struct ContentView: View {
    @Local private var selection: Tool? = .dashboard

    @StateObject private var dashboard = DashboardModel()
    @StateObject private var cleaner = CleanerModel()
    @StateObject private var privacy = PrivacyModel()
    @StateObject private var space = SpaceModel()
    @StateObject private var large = LargeFilesModel()
    @StateObject private var dups = DuplicatesModel()
    @StateObject private var dev = DevPurgeModel()
    @StateObject private var apps = UninstallerModel()
    @StateObject private var orphans = OrphansModel()
    @StateObject private var startup = StartupModel()
    @StateObject private var procs = ProcessesModel()
    @StateObject private var maint = MaintenanceModel()
    @StateObject private var tweaks = TweaksModel()
    @StateObject private var updates = UpdatesModel()
    @StateObject private var history = HistoryModel()
    @StateObject private var toggles = QuickTogglesModel()
    @StateObject private var customize = CustomizeModel()
    @StateObject private var network = NetworkModel()
    @StateObject private var battery = BatteryModel()
    @StateObject private var ports = PortsModel()
    @StateObject private var sensors = SensorsModel()
    @StateObject private var disks = DisksModel()
    @StateObject private var displays = DisplaysModel()
    @StateObject private var security = SecurityModel()
    @StateObject private var utilities = UtilitiesModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Aperçu") {
                    row(.dashboard)
                    row(.permissions)
                }
                Section("Nettoyage") {
                    row(.cleaner); row(.privacy); row(.space); row(.largeFiles); row(.duplicates); row(.devPurge)
                }
                Section("Matériel") { row(.battery); row(.ports); row(.sensors); row(.disks); row(.displays) }
                Section("Applications") { row(.uninstaller); row(.orphans); row(.startup) }
                Section("Performance") { row(.processes); row(.maintenance) }
                Section("Personnalisation") { row(.toggles); row(.customize); row(.windows); row(.clipboard); row(.utilities) }
                Section("Sécurité") { row(.security) }
                Section("Système") { row(.tweaks); row(.network); row(.updates); row(.history) }
                Section("Par \(Author.name)") { row(.myApps) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Boîte à outils")
        .onReceive(NotificationCenter.default.publisher(for: .openTool)) { n in
            if let t = n.object as? Tool { selection = t }
        }
    }

    private func row(_ t: Tool) -> some View {
        Label {
            if t == .permissions { PermissionsSidebarLabel(title: t.title) } else { Text(t.title) }
        } icon: { Image(systemName: t.icon).foregroundStyle(t.color) }
            .tag(t)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .dashboard {
        case .dashboard: DashboardView(model: dashboard, cleaner: cleaner) { selection = $0 }
        case .permissions: PermissionsView()
        case .cleaner: CleanerView(model: cleaner)
        case .privacy: PrivacyView(model: privacy)
        case .space: SpaceView(model: space)
        case .largeFiles: LargeFilesView(model: large)
        case .duplicates: DuplicatesView(model: dups)
        case .devPurge: DevPurgeView(model: dev)
        case .uninstaller: UninstallerView(model: apps)
        case .orphans: OrphansView(model: orphans)
        case .startup: StartupView(model: startup)
        case .processes: ProcessesView(model: procs)
        case .maintenance: MaintenanceView(model: maint)
        case .tweaks: TweaksView(model: tweaks)
        case .updates: UpdatesView(model: updates)
        case .history: HistoryView(model: history)
        case .toggles: QuickTogglesView(model: toggles)
        case .customize: CustomizeView(model: customize)
        case .windows: WindowsView()
        case .clipboard: ClipboardView()
        case .network: NetworkView(model: network)
        case .battery: BatteryView(model: battery)
        case .ports: PortsView(model: ports)
        case .sensors: SensorsView(model: sensors)
        case .disks: DisksView(model: disks)
        case .displays: DisplaysView(model: displays)
        case .security: SecurityView(model: security)
        case .utilities: UtilitiesView(model: utilities)
        case .myApps: MyAppsView()
        }
    }
}

/// Libellé de la ligne « Autorisations » avec le nombre d'autorisations manquantes.
/// Vue isolée : ses mises à jour ne reconstruisent pas la liste (ce qui faisait perdre la sélection).
/// Le modificateur `.badge` est évité : il décalait la sélection des lignes suivantes.
struct PermissionsSidebarLabel: View {
    let title: String
    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(center.missingRecommended)")
                .font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.orange))
                .opacity(center.missingRecommended > 0 ? 1 : 0)
        }
    }
}
