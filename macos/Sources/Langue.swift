// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import AppKit
import SwiftUI

/// Langue de l'interface. Les traductions sont dans Resources/<langue>.lproj (le texte français sert de clé) ;
/// macOS choisit parmi elles selon les langues préférées, l'anglais servant de repli.
/// Le choix fait dans les Options est enregistré pour l'app seule (AppleLanguages) et s'applique au prochain lancement.
enum Langue {
    static let codes = ["fr", "en", "es", "de", "it", "pt", "zh-Hans", "ja"]
    static let noms = ["Français", "English", "Español", "Deutsch", "Italiano", "Português", "中文（简体）", "日本語"]
    private static let regions = ["fr": "fr-FR", "en": "en-US", "es": "es-ES", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "zh-Hans": "zh-CN", "ja": "ja-JP"]

    /// Langue réellement utilisée par l'interface.
    static var actuelle: String { Bundle.main.preferredLocalizations.first.flatMap { codes.contains($0) ? $0 : nil } ?? "en" }
    /// Pour les services en ligne (Accept-Language, textes localisés des boutiques).
    static var bcp47: String { regions[actuelle] ?? "en-US" }
    /// Code court pour l'attribut lang d'un document.
    static var html: String { actuelle == "zh-Hans" ? "zh" : actuelle }

    /// "" = langue du système.
    static var choixEnregistre: String {
        guard let id = Bundle.main.bundleIdentifier,
              let l = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = l.first else { return "" }
        return codes.first { first == $0 || first.hasPrefix($0 + "-") } ?? ""
    }

    static func enregistrer(_ code: String) {
        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code == "pt" ? "pt-BR" : code], forKey: "AppleLanguages") }
    }

    static func relancer() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Sélecteur de langue des Options (sans @State : les macros SwiftUI ne sont pas disponibles avec les seuls outils en ligne de commande).
final class LangueChoix: ObservableObject {
    @Published var code = Langue.choixEnregistre { didSet { Langue.enregistrer(code); changee = true } }
    @Published var changee = false
}

struct LanguePicker: View {
    @StateObject private var m = LangueChoix()

    var body: some View {
        Picker("Langue", selection: $m.code) {
            Text("Langue du système").tag("")
            ForEach(Langue.codes.indices, id: \.self) { i in Text(verbatim: Langue.noms[i]).tag(Langue.codes[i]) }
        }
        if m.changee {
            HStack {
                Text("La nouvelle langue s'applique au prochain lancement.").foregroundStyle(.secondary)
                Spacer()
                Button("Relancer la Boîte à outils") { Langue.relancer() }
            }
        }
    }
}
