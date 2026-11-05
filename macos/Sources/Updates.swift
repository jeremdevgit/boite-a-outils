// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

final class UpdatesModel: ObservableObject {
    @Published var systemUpdates: [String] = []
    @Published var checking = false
    @Published var checked = false
    @Published var rawOutput = ""
    @Published var brewOutdated: [String]?
    @Published var appStoreApps = 0
    @Published var otherApps = 0

    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }

    func check() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.exec("/usr/sbin/softwareupdate", ["--list"])
            let ups = r.output.split(separator: "\n").compactMap { line -> String? in
                guard let t = line.range(of: "Title: ") else { return nil }
                let rest = line[t.upperBound...]
                return String(rest.split(separator: ",").prefix(2).joined(separator: ","))
            }

            var brew: [String]?
            if let b = Self.brew {
                let o = Shell.exec(b, ["outdated", "--verbose"]).output
                brew = o.isEmpty ? [] : o.components(separatedBy: "\n")
            }

            var mas = 0, other = 0
            for u in FS.children(URL(fileURLWithPath: "/Applications")) where u.pathExtension == "app" {
                if FS.exists(u.appendingPathComponent("Contents/_MASReceipt")) { mas += 1 } else { other += 1 }
            }

            DispatchQueue.main.async {
                self.systemUpdates = ups
                self.rawOutput = r.output
                self.brewOutdated = brew
                self.appStoreApps = mas
                self.otherApps = other
                self.checking = false
                self.checked = true
            }
        }
    }
}

struct UpdatesView: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Mises à jour", subtitle: "Gardez macOS et vos applications à jour",
                           icon: "arrow.down.circle.fill", color: .cyan) {
                    if model.checking { ProgressView().controlSize(.small) }
                    Button { model.check() } label: { Label("Rechercher", systemImage: "arrow.clockwise") }
                        .disabled(model.checking)
                }

                Group {
                    Card(title: "macOS", icon: "apple.logo") {
                        if model.checking && !model.checked {
                            Text("Interrogation des serveurs Apple… (peut prendre une minute)").foregroundStyle(.secondary)
                        } else if model.systemUpdates.isEmpty {
                            Label("Aucune mise à jour système disponible.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            ForEach(model.systemUpdates, id: \.self) { u in
                                Label(u, systemImage: "arrow.down.circle").foregroundStyle(.orange)
                            }
                        }
                        Button("Ouvrir Mise à jour de logiciels…") {
                            Permissions.openSettings("x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
                        }
                    }

                    Card(title: "Applications", icon: "square.grid.2x2") {
                        Text("\(model.appStoreApps) applications de l'App Store · \(model.otherApps) installées autrement")
                            .foregroundStyle(.secondary)
                        Text("Les apps de l'App Store se mettent à jour depuis l'App Store ; les autres via leur menu « Rechercher les mises à jour ».")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Ouvrir les mises à jour de l'App Store…") {
                            if let u = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(u) }
                        }
                    }

                    if let brew = model.brewOutdated {
                        Card(title: "Homebrew", icon: "mug") {
                            if brew.isEmpty {
                                Label("Tous les paquets sont à jour.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                ForEach(brew, id: \.self) { Text($0).font(.system(.callout, design: .monospaced)) }
                                Text("Pour tout mettre à jour : brew upgrade").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { if !model.checked && !model.checking { model.check() } }
    }
}
