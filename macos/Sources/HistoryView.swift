// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct HistoryEntry: Identifiable {
    let id = UUID()
    let date: String
    let action: String
    let path: String
}

final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var filter = ""

    var visible: [HistoryEntry] {
        filter.isEmpty ? entries : entries.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    func load() {
        let text = (try? String(contentsOf: History.url, encoding: .utf8)) ?? ""
        entries = text.split(separator: "\n").reversed().compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 2)
            return p.count == 3 ? HistoryEntry(date: String(p[0]), action: String(p[1]), path: String(p[2])) : nil
        }
    }

    func clear() {
        try? FS.fm.removeItem(at: History.url)
        entries = []
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Historique"), subtitle: String(localized: "Tout ce que la Boîte à outils a supprimé ou mis à la corbeille"),
                       icon: "clock.arrow.circlepath", color: .secondary) {
                TextField("Filtrer", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Ouvrir la corbeille") { NSWorkspace.shared.open(FS.home.appendingPathComponent(".Trash")) }
            }
            if model.entries.isEmpty {
                EmptyState(icon: "clock", title: String(localized: "Historique vide"), message: String(localized: "Les suppressions effectuées apparaîtront ici."))
            } else {
                List(model.visible) { e in
                    HStack(spacing: 10) {
                        Image(systemName: e.action == "Corbeille" ? "trash" : "xmark.circle")
                            .foregroundStyle(e.action == "Corbeille" ? Color.orange : Color.red).frame(width: 18)
                        Text(e.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                        Text(LocalizedStringKey(e.action)).font(.caption).frame(width: 70, alignment: .leading)
                        Text(e.path.replacingOccurrences(of: FS.home.path, with: "~", options: .anchored))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                BottomBar {
                    Text("\(model.entries.count) opérations · les éléments « Corbeille » sont restaurables tant qu'elle n'est pas vidée.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Effacer l'historique") { confirm = true }
                }
            }
        }
        .onAppear { model.load() }
        .confirmationDialog("Effacer l'historique ?", isPresented: $confirm) {
            Button("Effacer", role: .destructive) { model.clear() }
        }
    }
}
