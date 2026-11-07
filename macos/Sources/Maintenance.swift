// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct MaintTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let admin: Bool
    let command: String
    var selected = false

    static let all: [MaintTask] = [
        MaintTask(id: "dns", title: String(localized: "Vider le cache DNS"),
                  detail: String(localized: "Corrige les sites qui ne se chargent plus ou les problèmes de réseau."),
                  icon: "network", admin: true, command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
        MaintTask(id: "ram", title: String(localized: "Libérer la mémoire inactive"),
                  detail: String(localized: "Purge la mémoire inactive et les caches disque."),
                  icon: "memorychip", admin: true, command: "purge"),
        MaintTask(id: "snapshots", title: String(localized: "Supprimer les instantanés Time Machine locaux"),
                  detail: String(localized: "Récupère l'espace « purgeable » occupé par les instantanés."),
                  icon: "clock.arrow.circlepath", admin: true,
                  command: "tmutil listlocalsnapshots /; tmutil thinlocalsnapshots / 999999999999 4"),
        MaintTask(id: "spotlight", title: String(localized: "Réindexer Spotlight"),
                  detail: String(localized: "Reconstruit l'index de recherche (résultats manquants, « mds » gourmand). Long."),
                  icon: "magnifyingglass", admin: true, command: "mdutil -E /"),
        MaintTask(id: "perms", title: String(localized: "Réparer les permissions du dossier personnel"),
                  detail: String(localized: "Rétablit les droits d'accès par défaut de vos fichiers. Peut prendre plusieurs minutes."),
                  icon: "lock.shield", admin: true, command: "diskutil resetUserPermissions / \(getuid())"),
        MaintTask(id: "launchservices", title: String(localized: "Reconstruire la base « Ouvrir avec »"),
                  detail: String(localized: "Supprime les doublons et applications fantômes du menu « Ouvrir avec »."),
                  icon: "list.bullet.rectangle", admin: false,
                  command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user && echo 'Base reconstruite.'"),
        MaintTask(id: "quicklook", title: String(localized: "Réinitialiser Coup d'œil (Quick Look)"),
                  detail: String(localized: "Corrige les aperçus et vignettes qui ne s'affichent plus."),
                  icon: "eye", admin: false, command: "qlmanage -r cache; qlmanage -r"),
        MaintTask(id: "fonts", title: String(localized: "Nettoyer les caches de polices"),
                  detail: String(localized: "Corrige les polices mal affichées. Redémarrage conseillé ensuite."),
                  icon: "textformat", admin: false, command: "atsutil databases -removeUser"),
        MaintTask(id: "disk", title: String(localized: "Vérifier le disque de démarrage"),
                  detail: String(localized: "Contrôle l'intégrité du volume (S.O.S., sans modification)."),
                  icon: "internaldrive", admin: false, command: "diskutil verifyVolume /"),
        MaintTask(id: "ui", title: String(localized: "Relancer Finder, Dock et barre des menus"),
                  detail: String(localized: "Utile quand l'interface se fige ou se comporte bizarrement."),
                  icon: "dock.rectangle", admin: false, command: "killall Finder; killall Dock; killall SystemUIServer; echo 'Relancés.'"),
        MaintTask(id: "trash", title: String(localized: "Vider la corbeille"),
                  detail: String(localized: "Supprime définitivement le contenu de la corbeille."),
                  icon: "trash", admin: false, command: "osascript -e 'tell application \"Finder\" to empty trash' && echo 'Corbeille vidée.'"),
        MaintTask(id: "clipboard", title: String(localized: "Vider le presse-papiers"),
                  detail: String(localized: "Efface le contenu copié (mots de passe, données sensibles)."),
                  icon: "doc.on.clipboard", admin: false, command: "pbcopy < /dev/null && echo 'Presse-papiers vidé.'"),
        MaintTask(id: "security", title: String(localized: "Audit de sécurité"),
                  detail: String(localized: "Affiche l'état de SIP, Gatekeeper, FileVault et du pare-feu."),
                  icon: "checkmark.shield", admin: false,
                  command: "echo \"SIP : $(csrutil status)\"; echo \"Gatekeeper : $(spctl --status)\"; echo \"FileVault : $(fdesetup status)\"; echo \"Pare-feu : $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate)\""),
    ]
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    var kind: Kind = .output
    enum Kind { case title, output, success, error }
}

final class MaintenanceModel: ObservableObject {
    @Published var tasks = MaintTask.all
    @Published var log: [LogLine] = []
    @Published var running: Set<String> = []

    var selected: [MaintTask] { tasks.filter(\.selected) }

    private func append(_ text: String, _ kind: LogLine.Kind) {
        DispatchQueue.main.async { self.log.append(LogLine(text: text, kind: kind)) }
    }

    private func finish(_ ids: [String]) {
        DispatchQueue.main.async { ids.forEach { self.running.remove($0) } }
    }

    func run(_ list: [MaintTask]) {
        let list = list.filter { !running.contains($0.id) }
        guard !list.isEmpty else { return }
        list.forEach { running.insert($0.id) }
        DispatchQueue.global(qos: .userInitiated).async {
            for t in list where !t.admin {
                self.append("▶︎ \(t.title)", .title)
                let r = Shell.sh(t.command)
                if !r.output.isEmpty { self.append(r.output, .output) }
                self.append(r.ok ? String(localized: "✓ Terminé") : String(localized: "✗ Échec (code \(r.status))"), r.ok ? .success : .error)
                self.finish([t.id])
            }
            // Toutes les tâches administrateur en une seule demande de mot de passe.
            let admin = list.filter(\.admin)
            if !admin.isEmpty {
                self.append("▶︎ " + admin.map(\.title).joined(separator: " · ") + String(localized: " (administrateur)"), .title)
                let script = admin.map { "echo '— \($0.id)'; (\($0.command)) 2>&1" }.joined(separator: "; ") + "; true"
                let r = Shell.admin(script)
                if !r.output.isEmpty { self.append(r.output, .output) }
                self.append(r.ok ? String(localized: "✓ Terminé") : String(localized: "✗ Annulé ou échec"), r.ok ? .success : .error)
                self.finish(admin.map(\.id))
            }
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Maintenance"), subtitle: String(localized: "Scripts d'entretien et de réparation de macOS"),
                       icon: "wrench.and.screwdriver.fill", color: .gray) {
                Button("Exécuter la sélection (\(model.selected.count))") { model.run(model.selected) }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
            }
            VSplitView {
                List($model.tasks) { $t in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $t.selected).labelsHidden().toggleStyle(.checkbox)
                        Image(systemName: t.icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(t.title).bold()
                                if t.admin {
                                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange)
                                        .help("Mot de passe administrateur requis")
                                }
                            }
                            Text(t.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.running.contains(t.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Exécuter") { model.run([t]) }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 260)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Journal").font(.headline)
                        Spacer()
                        Button("Copier") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.log.map(\.text).joined(separator: "\n"), forType: .string)
                        }.disabled(model.log.isEmpty)
                        Button("Effacer") { model.log.removeAll() }.disabled(model.log.isEmpty)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(model.log) { l in
                                    Text(l.text)
                                        .font(.system(.callout, design: .monospaced).weight(l.kind == .title ? .bold : .regular))
                                        .foregroundStyle(color(l.kind))
                                        .textSelection(.enabled)
                                        .id(l.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                        }
                        .onChange(of: model.log.count) { _, _ in
                            if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .frame(minHeight: 140)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .title: .primary
        case .output: .secondary
        case .success: .green
        case .error: .red
        }
    }
}
