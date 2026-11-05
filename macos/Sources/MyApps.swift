// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

/// Logiciels de l'auteur (jeremdevgit), avec le lien de téléchargement officiel sur GitHub.
struct MyApp: Identifiable {
    let name: String
    let platform: String
    let summary: String
    let icon: String
    let color: Color
    let url: URL
    var id: String { name }
}

enum Author {
    static let name = "jeremdevgit"
    static let profile = URL(string: "https://github.com/jeremdevgit")!
    static let apps: [MyApp] = [
        MyApp(name: "Boîte à outils pour Windows", platform: "Windows",
              summary: "La même idée pour le PC : démarrage, services, nettoyage, réglages cachés et diagnostic du matériel.",
              icon: "wrench.and.screwdriver.fill", color: .blue,
              url: URL(string: "https://github.com/jeremdevgit/boite-a-outils/releases/latest")!),
        MyApp(name: "Ludothèque", platform: "macOS",
              summary: "Tous vos jeux au même endroit : Steam, Epic, GOG, émulateurs… avec statistiques, succès et mode TV.",
              icon: "gamecontroller.fill", color: .purple,
              url: URL(string: "https://github.com/jeremdevgit/ludotheque/releases/latest")!),
        MyApp(name: "Pomme", platform: "Windows",
              summary: "Lecteur de musique léger pour Apple Music et vos fichiers audio locaux.",
              icon: "music.note", color: .pink,
              url: URL(string: "https://github.com/jeremdevgit/pomme/releases/latest")!),
        MyApp(name: "rJb", platform: "Windows",
              summary: "L'éclairage RGB de tous vos périphériques et composants dans une seule application.",
              icon: "light.max", color: .orange,
              url: URL(string: "https://github.com/jeremdevgit/rjb/releases/latest")!),
        MyApp(name: "Suite Libre", platform: "Navigateur",
              summary: "Six outils sans compte : QR codes, flou d'images, compression de photos, conversions, moyennes, mots de passe.",
              icon: "lock.shield.fill", color: .green,
              url: URL(string: "https://jeremdevgit.github.io/suite-libre/")!),
        MyApp(name: "Batailles de France", platform: "Navigateur",
              summary: "Jeu de stratégie en temps réel sur les cartes de Lyon, Paris, Marseille, Bordeaux et Strasbourg.",
              icon: "flag.2.crossed.fill", color: .red,
              url: URL(string: "https://github.com/jeremdevgit/batailles-de-france/releases/latest")!),
    ]
}

struct MyAppsView: View {
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Mes logiciels", subtitle: "La Boîte à outils est créée par \(Author.name). Ses autres logiciels sont libres, gratuits et sans publicité.",
                       icon: "square.grid.2x2.fill", color: .purple) {
                Link("Tous mes logiciels sur GitHub", destination: Author.profile).buttonStyle(.bordered)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Author.apps) { app in
                        Card {
                            HStack(spacing: 12) {
                                Image(systemName: app.icon)
                                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(app.color.gradient))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.headline)
                                    Text(app.platform).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(app.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Link("Télécharger", destination: app.url).buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                Text("Chaque bouton ouvre la page de téléchargement officielle sur GitHub, dans votre navigateur.")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 24)
            }
        }
    }
}
