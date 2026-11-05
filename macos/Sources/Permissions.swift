// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import CoreServices
import ApplicationServices
import ServiceManagement
import UserNotifications

enum PermState {
    case granted, denied, notDetermined, unknown
}

enum PermKind: String, CaseIterable, Identifiable {
    case fullDisk, finder, systemEvents, accessibility, appManagement, screenRecording, notifications, loginItem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDisk: "Accès complet au disque"
        case .finder: "Contrôle du Finder"
        case .systemEvents: "Contrôle de « System Events »"
        case .accessibility: "Accessibilité"
        case .appManagement: "Gestion des applications"
        case .screenRecording: "Enregistrement de l'écran"
        case .notifications: "Notifications"
        case .loginItem: "Ouverture à la connexion"
        }
    }

    var icon: String {
        switch self {
        case .fullDisk: "externaldrive.fill.badge.checkmark"
        case .finder: "folder.fill"
        case .systemEvents: "gearshape.2.fill"
        case .accessibility: "accessibility"
        case .appManagement: "app.badge.checkmark"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .notifications: "bell.badge.fill"
        case .loginItem: "power"
        }
    }

    var usage: String {
        switch self {
        case .fullDisk: "Analyse de Mail, Safari, de la corbeille et des conteneurs d'apps (Nettoyage, Confidentialité, Restes orphelins)."
        case .finder: "Vider la corbeille, éjecter les disques, supprimer les fichiers protégés lors d'une désinstallation."
        case .systemEvents: "Mode sombre, éléments d'ouverture, mise en sourdine."
        case .accessibility: "Rangement des fenêtres au clavier (module Fenêtres)."
        case .appManagement: "Désinstaller des apps et changer leur icône sans blocage de macOS."
        case .screenRecording: "Copier le texte d'une zone de l'écran (OCR, module Utilitaires)."
        case .notifications: "Alertes de sécurité : nouvel élément au démarrage, caméra ou micro activés."
        case .loginItem: "Lancer la Boîte à outils au démarrage (moniteur de la barre des menus, presse-papiers)."
        }
    }

    var recommended: Bool { self == .fullDisk || self == .finder || self == .systemEvents }

    /// Ancre du panneau « Confidentialité et sécurité ».
    var pane: String? {
        switch self {
        case .fullDisk: "Privacy_AllFiles"
        case .finder, .systemEvents: "Privacy_Automation"
        case .accessibility: "Privacy_Accessibility"
        case .appManagement: "Privacy_AppBundles"
        case .screenRecording: "Privacy_ScreenCapture"
        case .notifications: nil
        case .loginItem: nil
        }
    }

    /// Service TCC, pour la réinitialisation.
    var tccService: String? {
        switch self {
        case .fullDisk: "SystemPolicyAllFiles"
        case .finder, .systemEvents: "AppleEvents"
        case .accessibility: "Accessibility"
        case .appManagement: "SystemPolicyAppBundles"
        case .screenRecording: "ScreenCapture"
        case .notifications, .loginItem: nil
        }
    }

    /// Étapes affichées pour les autorisations sans demande système directe.
    var steps: [String] {
        switch self {
        case .fullDisk, .appManagement:
            ["Le bon panneau des Réglages s'ouvre, avec la Boîte à outils affichée dans le Finder.",
             "Activez l'interrupteur « Boîte à outils » (ou glissez l'icône depuis le Finder dans la liste).",
             "Revenez ici : la coche verte apparaît toute seule."]
        case .finder, .systemEvents:
            ["Cliquez sur « Autoriser » dans la fenêtre que macOS affiche.",
             "Si vous aviez refusé, activez l'interrupteur dans Réglages › Automatisation › Boîte à outils."]
        case .accessibility, .screenRecording:
            ["Dans la fenêtre de macOS, cliquez sur « Ouvrir Réglages Système ».",
             "Activez l'interrupteur « Boîte à outils ». macOS peut demander de relancer l'app."]
        case .notifications:
            ["Cliquez sur « Autoriser » dans la fenêtre de macOS (ou activez-les dans Réglages › Notifications)."]
        case .loginItem:
            ["Un clic suffit. Si macOS le demande, validez dans Réglages › Ouverture."]
        }
    }
}

/// Vérifie et demande les autorisations macOS (TCC) de l'application.
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.boiteaoutils.mac"

    @Published var states: [PermKind: PermState] = [:]
    @Published var justGranted: PermKind?
    @Published var awaiting: PermKind?
    @Published var checking = false

    private var timer: Timer?
    private var awaitingSince = Date()
    private let queue = DispatchQueue(label: "permissions")

    var missingRecommended: Int { PermKind.allCases.filter { $0.recommended && states[$0] != .granted }.count }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(full: true)
        }
        refresh(full: true)
    }

    // MARK: Vérifications

    func refresh(full: Bool = false) {
        checking = true
        queue.async {
            var s: [PermKind: PermState] = [:]
            s[.fullDisk] = Self.checkFullDisk()
            s[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
            s[.finder] = Self.checkAutomation("com.apple.finder", ask: false)
            s[.systemEvents] = Self.checkAutomation("com.apple.systemevents", ask: false)
            s[.loginItem] = Self.checkLoginItem()
            s[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .denied
            // « Gestion des apps » : test uniquement à la demande (il tente d'écrire dans une app tierce).
            if full && self.awaiting == .appManagement { s[.appManagement] = Self.checkAppManagement() }
            let sem = DispatchSemaphore(value: 0)
            // Le centre de notifications n'existe que pour une app empaquetée (.app).
            if Bundle.main.bundleIdentifier == nil { sem.signal() } else { UNUserNotificationCenter.current().getNotificationSettings { st in
                switch st.authorizationStatus {
                case .authorized, .provisional: s[.notifications] = .granted
                case .denied: s[.notifications] = .denied
                default: s[.notifications] = .notDetermined
                }
                sem.signal()
            } }
            _ = sem.wait(timeout: .now() + 2)
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    private func apply(_ new: [PermKind: PermState]) {
        for (k, v) in new {
            // « System Events » non lancé : on garde le dernier état connu.
            if v == .unknown, let old = states[k], old != .unknown { continue }
            if v == .granted, let old = states[k], old != .granted, awaiting == k || old == .denied || old == .notDetermined {
                justGranted = k
                if awaiting == k { awaiting = nil; stopPolling() }
                NSSound(named: "Glass")?.play()
                NSApp.activate(ignoringOtherApps: true)
            }
            states[k] = v
        }
        checking = false
    }

    /// Lecture d'un dossier protégé par la confidentialité : réussite = accès accordé.
    static func checkFullDisk() -> PermState {
        let probes = ["Library/Containers/com.apple.stocks", "Library/Safari", "Library/Mail", "Library/Messages",
                      "Library/Cookies", "Library/Containers/com.apple.Safari", ".Trash"]
        var blocked = false
        for p in probes {
            let path = FS.home.appendingPathComponent(p).path
            if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil { return .granted }
            if FileManager.default.fileExists(atPath: path) { blocked = true }
        }
        return blocked ? .denied : .unknown
    }

    static func checkAutomation(_ bundleID: String, ask: Bool) -> PermState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown     // application cible non lancée
        }
    }

    /// Tente de créer puis supprimer un fichier vide dans une app tierce : macOS le bloque sans « Gestion des applications ».
    static func checkAppManagement() -> PermState {
        for app in FS.children(URL(fileURLWithPath: "/Applications")) where app.pathExtension == "app" {
            guard let info = FS.appInfo(app), let id = info["CFBundleIdentifier"] as? String,
                  !id.hasPrefix("com.apple."), id != bundleID,
                  FS.exists(app.appendingPathComponent("Contents")),
                  (try? FileManager.default.attributesOfItem(atPath: app.path)[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { continue }
            let probe = app.appendingPathComponent(".boiteaoutils-probe").path
            let fd = open(probe, O_CREAT | O_WRONLY | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                unlink(probe)
                return .granted
            }
            if errno == EPERM { return .denied }
        }
        return .unknown
    }

    static func checkLoginItem() -> PermState {
        switch SMAppService.mainApp.status {
        case .enabled: return .granted
        case .requiresApproval: return .notDetermined
        case .notRegistered: return .denied
        default: return .unknown
        }
    }

    // MARK: Demandes (chemin le plus court pour chaque autorisation)

    func request(_ kind: PermKind) {
        justGranted = nil
        awaiting = kind
        startPolling()
        switch kind {
        case .fullDisk, .appManagement:
            openPane(kind)
            // Fenêtre Finder avec l'app sélectionnée, prête à être glissée dans la liste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { FS.reveal([Bundle.main.bundleURL]) }
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .finder, .systemEvents:
            let id = kind == .finder ? "com.apple.finder" : "com.apple.systemevents"
            queue.async {
                if kind == .systemEvents { Self.launchSystemEvents() }
                let r = Self.checkAutomation(id, ask: true)      // affiche la fenêtre « Autoriser » de macOS
                DispatchQueue.main.async {
                    if r == .denied { self.openPane(kind) }       // déjà refusé : macOS ne redemande pas
                    self.refresh()
                }
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openPane(kind) }
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                DispatchQueue.main.async {
                    if !ok { Permissions.openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
                    self.refresh()
                }
            }
        case .loginItem:
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch {}
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            refresh()
        }
    }

    func testAppManagement() {
        checking = true
        queue.async {
            let r = Self.checkAppManagement()
            DispatchQueue.main.async {
                self.states[.appManagement] = r    // .unknown : aucune app tierce testable trouvée
                self.checking = false
            }
        }
    }

    func openPane(_ kind: PermKind) {
        if kind == .notifications { Permissions.openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension"); return }
        guard let pane = kind.pane else { SMAppService.openSystemSettingsLoginItems(); return }
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)")!
        if !NSWorkspace.shared.open(modern) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    /// Efface l'entrée de l'app dans la base des autorisations (utile après une mise à jour si l'interrupteur
    /// est activé mais l'autorisation non reconnue), puis relance la demande.
    func reset(_ kind: PermKind) {
        guard let service = kind.tccService else { return }
        queue.async {
            Shell.exec("/usr/bin/tccutil", ["reset", service, Self.bundleID])
            DispatchQueue.main.async {
                self.states[kind] = .notDetermined
                self.request(kind)
            }
        }
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \(Shell.quote(path))"]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func launchSystemEvents() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty else { return }
        Shell.exec("/usr/bin/open", ["-gj", "-b", "com.apple.systemevents"])
        Thread.sleep(forTimeInterval: 1.2)
    }

    private func startPolling() {
        awaitingSince = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.awaitingSince) > 300 { self.awaiting = nil; self.stopPolling(); return }
            self.refresh(full: self.awaiting == .appManagement)
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Vue

struct PermissionsView: View {
    @ObservedObject var center = PermissionCenter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Autorisations", subtitle: "Ce que macOS doit autoriser pour que chaque outil fonctionne",
                           icon: "lock.shield.fill", color: .green) {
                    if center.checking { ProgressView().controlSize(.small) }
                    Button { center.refresh(full: true) } label: { Label("Revérifier", systemImage: "arrow.clockwise") }
                }

                Group {
                    if let k = center.justGranted {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                            Text("« \(k.title) » est accordé : c'est confirmé. ✅").bold()
                            Spacer()
                            Button { center.justGranted = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.15)))
                    }

                    summary

                    ForEach(PermKind.allCases) { k in row(k) }

                    Card(title: "L'interrupteur est activé mais l'app ne le voit pas ?", icon: "questionmark.circle") {
                        Text("Après une réinstallation ou une mise à jour, macOS peut garder une ancienne autorisation qui ne correspond plus à l'app. Cliquez sur « Réinitialiser » sur la ligne concernée puis réactivez l'interrupteur. Pour l'accès complet au disque, relancer l'app peut aussi être nécessaire.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Relancer la Boîte à outils") { center.relaunch() }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { center.refresh(full: true) }
    }

    private var summary: some View {
        let missing = center.missingRecommended
        return HStack(spacing: 10) {
            Image(systemName: missing == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title).foregroundStyle(missing == 0 ? .green : .orange)
            Text(missing == 0 ? "Toutes les autorisations recommandées sont accordées."
                              : "\(missing) autorisation(s) recommandée(s) manquante(s).")
                .font(.headline)
        }
    }

    @ViewBuilder private func row(_ k: PermKind) -> some View {
        let state = center.states[k] ?? .unknown
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: k.icon).font(.title2).frame(width: 32).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(k.title).font(.headline)
                        if k.recommended {
                            Text("Recommandée").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                    }
                    Text(k.usage).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if center.awaiting == k && state != .granted {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(k.steps.enumerated()), id: \.offset) { i, s in
                                Text("\(i + 1). \(s)").font(.callout)
                            }
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("En attente de l'autorisation…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    badge(state, k)
                    HStack {
                        if state != .granted {
                            Button(k == .loginItem ? "Activer" : "Autoriser") { center.request(k) }
                                .buttonStyle(.borderedProminent)
                        } else if k == .loginItem {
                            Button("Désactiver") { center.request(k) }
                        }
                        if k == .appManagement {
                            Button("Tester") { center.testAppManagement() }
                                .help("Crée puis supprime aussitôt un fichier vide dans une application tierce pour vérifier l'accès.")
                        }
                        Menu {
                            Button("Ouvrir le réglage") { center.openPane(k) }
                            if k.tccService != nil { Button("Réinitialiser et redemander") { center.reset(k) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }
    }

    private func badge(_ s: PermState, _ k: PermKind) -> some View {
        let (text, color, icon): (String, Color, String) = switch s {
        case .granted: ("Accordée", .green, "checkmark.circle.fill")
        case .denied: (k == .loginItem ? "Désactivée" : "Non accordée", k.recommended ? .orange : .secondary, "xmark.circle.fill")
        case .notDetermined: (k == .loginItem ? "À valider" : "Jamais demandée", .orange, "questionmark.circle.fill")
        case .unknown: (k == .appManagement ? "À tester" : "Indéterminée", .secondary, "minus.circle")
        }
        return Label(text, systemImage: icon).foregroundStyle(color).font(.callout.bold())
    }
}

/// Bandeau affiché dans les modules qui ont besoin de l'accès complet au disque.
struct FullDiskAccessBanner: View {
    @ObservedObject var center = PermissionCenter.shared

    var body: some View {
        if center.states[.fullDisk] == .denied || center.states[.fullDisk] == .notDetermined {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                Text("Sans l'« Accès complet au disque », certains dossiers (Mail, Corbeille, Safari…) ne peuvent pas être analysés.")
                    .font(.callout)
                Spacer()
                Button("Autoriser…") { center.request(.fullDisk) }
                Button("Autorisations") { NotificationCenter.default.post(name: .openTool, object: Tool.permissions) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            .padding(.horizontal, 24)
        }
    }
}

extension Notification.Name {
    static let openTool = Notification.Name("BoiteAOutils.openTool")
}
