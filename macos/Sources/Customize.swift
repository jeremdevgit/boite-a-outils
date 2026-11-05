// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import UniformTypeIdentifiers

/// Personnalisation de l'apparence et du comportement de macOS (inspiré de TinkerTool, OnyX, MacPilot).
final class CustomizeModel: ObservableObject {
    @Published var accent = -2                // -2 : multicolore
    @Published var style = 0                  // 0 clair, 1 sombre, 2 automatique
    @Published var wallpaper: URL?
    @Published var dockSize: Double = 48
    @Published var dockMagnify = false
    @Published var dockLarge: Double = 72
    @Published var dockPosition = "bottom"
    @Published var minEffect = "genie"
    @Published var corners = [1, 1, 1, 1]     // haut-gauche, haut-droit, bas-gauche, bas-droit
    @Published var menuSpacing: Double = 0    // 0 : valeur par défaut
    @Published var loginMessage = ""
    @Published var startupChime = false
    @Published var computerName = ""
    @Published var loaded = false
    @Published var message: String?

    static let accents: [(value: Int, name: String, color: Color)] = [
        (-2, "Multicolore", .gray), (4, "Bleu", .blue), (5, "Violet", .purple), (6, "Rose", .pink), (0, "Rouge", .red),
        (1, "Orange", .orange), (2, "Jaune", .yellow), (3, "Vert", .green), (-1, "Graphite", Color(white: 0.55)),
    ]

    static let cornerActions: [(Int, String)] = [
        (1, "—"), (2, "Mission Control"), (3, "Fenêtres de l'app"), (4, "Bureau"), (11, "Launchpad"),
        (12, "Centre de notifications"), (5, "Économiseur d'écran"), (6, "Désactiver l'économiseur"),
        (10, "Suspendre l'écran"), (13, "Verrouiller l'écran"), (14, "Note rapide"),
    ]
    static let cornerKeys = ["wvous-tl-corner", "wvous-tr-corner", "wvous-bl-corner", "wvous-br-corner"]

    private func write(_ domain: String, _ key: String, _ type: String, _ value: String, currentHost: Bool = false) {
        Shell.exec("/usr/bin/defaults", (currentHost ? ["-currentHost"] : []) + ["write", domain, key, "-\(type)", value])
    }

    private func delete(_ domain: String, _ key: String, currentHost: Bool = false) {
        Shell.exec("/usr/bin/defaults", (currentHost ? ["-currentHost"] : []) + ["delete", domain, key])
    }

    private func background(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    private func say(_ s: String) { DispatchQueue.main.async { self.message = s } }

    func load() {
        background {
            let accent = Mac.readDefault("-g", "AppleAccentColor").flatMap { Int($0) } ?? -2
            let auto = Mac.readDefault("-g", "AppleInterfaceStyleSwitchesAutomatically") == "1"
            let style = auto ? 2 : (Mac.isDark ? 1 : 0)
            let size = Mac.readDefault("com.apple.dock", "tilesize").flatMap { Double($0) } ?? 48
            let magnify = Mac.readDefault("com.apple.dock", "magnification") == "1"
            let large = Mac.readDefault("com.apple.dock", "largesize").flatMap { Double($0) } ?? 72
            let pos = Mac.readDefault("com.apple.dock", "orientation") ?? "bottom"
            let effect = Mac.readDefault("com.apple.dock", "mineffect") ?? "genie"
            let corners = Self.cornerKeys.map { k -> Int in
                let v = Mac.readDefault("com.apple.dock", k).flatMap { Int($0) } ?? 1
                return v == 0 ? 1 : v
            }
            let spacing = Mac.readDefault("-globalDomain", "NSStatusItemSpacing", currentHost: true).flatMap { Double($0) } ?? 0
            let login = Mac.readDefault("/Library/Preferences/com.apple.loginwindow", "LoginwindowText") ?? ""
            let chime = !Shell.exec("/usr/sbin/nvram", ["StartupMute"]).output.hasSuffix("%01")
            let name = Shell.exec("/usr/sbin/scutil", ["--get", "ComputerName"]).output
            let wall = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            DispatchQueue.main.async {
                self.accent = accent; self.style = style
                self.dockSize = size; self.dockMagnify = magnify; self.dockLarge = large
                self.dockPosition = pos; self.minEffect = effect; self.corners = corners
                self.menuSpacing = spacing; self.loginMessage = login; self.startupChime = chime
                self.computerName = name; self.wallpaper = wall
                self.loaded = true
            }
        }
    }

    // MARK: Apparence

    func setAccent(_ v: Int) {
        accent = v
        background {
            if v == -2 { self.delete("-g", "AppleAccentColor") } else { self.write("-g", "AppleAccentColor", "int", String(v)) }
            self.delete("-g", "AppleHighlightColor")      // la couleur de sélection suit l'accentuation
            Mac.postColorChange()
        }
    }

    func setStyle(_ v: Int) {
        style = v
        background {
            if v == 2 {
                self.write("-g", "AppleInterfaceStyleSwitchesAutomatically", "bool", "true")
                Mac.postColorChange()
            } else {
                self.delete("-g", "AppleInterfaceStyleSwitchesAutomatically")
                Mac.setDark(v == 1)
            }
        }
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            for s in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [:]) }
            wallpaper = url
            message = "Fond d'écran appliqué à tous les écrans."
        } catch {
            message = "Impossible d'appliquer ce fond d'écran : \(error.localizedDescription)"
        }
    }

    // MARK: Dock

    func applyDock() {
        let size = Int(dockSize), large = Int(dockLarge), magnify = dockMagnify, pos = dockPosition, effect = minEffect
        background {
            self.write("com.apple.dock", "tilesize", "int", String(size))
            self.write("com.apple.dock", "magnification", "bool", magnify ? "true" : "false")
            self.write("com.apple.dock", "largesize", "int", String(large))
            self.write("com.apple.dock", "orientation", "string", pos)
            self.write("com.apple.dock", "mineffect", "string", effect)
            Mac.killall("Dock")
        }
    }

    func addDockSpacer(small: Bool) {
        background {
            Shell.exec("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add",
                                             "{\"tile-type\"=\"\(small ? "small-spacer-tile" : "spacer-tile")\";}"])
            Mac.killall("Dock")
            self.say("Séparateur ajouté à la fin des apps du Dock. Faites-le glisser où vous voulez, ou hors du Dock pour le retirer.")
        }
    }

    // MARK: Coins actifs

    func setCorner(_ index: Int, _ value: Int) {
        corners[index] = value
        background {
            self.write("com.apple.dock", Self.cornerKeys[index], "int", String(value))
            self.write("com.apple.dock", Self.cornerKeys[index].replacingOccurrences(of: "corner", with: "modifier"), "int", "0")
            Mac.killall("Dock")
        }
    }

    // MARK: Barre des menus

    func applyMenuSpacing() {
        let v = Int(menuSpacing)
        background {
            if v == 0 {
                self.delete("-globalDomain", "NSStatusItemSpacing", currentHost: true)
                self.delete("-globalDomain", "NSStatusItemSelectionPadding", currentHost: true)
            } else {
                self.write("-globalDomain", "NSStatusItemSpacing", "int", String(v), currentHost: true)
                self.write("-globalDomain", "NSStatusItemSelectionPadding", "int", String(max(v - 2, 4)), currentHost: true)
            }
            Mac.killall("SystemUIServer")
            Mac.killall("ControlCenter")
            self.say("Espacement appliqué. Si rien ne change, fermez puis rouvrez votre session.")
        }
    }

    // MARK: Démarrage et identité (administrateur)

    func applyLoginMessage(_ text: String?) {
        background {
            let path = "/Library/Preferences/com.apple.loginwindow"
            let cmd = text.map { "defaults write \(path) LoginwindowText \(Shell.quote($0))" } ?? "defaults delete \(path) LoginwindowText"
            let r = Shell.admin(cmd)
            self.say(r.ok ? (text == nil ? "Message retiré." : "Message affiché sur l'écran de verrouillage.") : "Annulé.")
            if text == nil && r.ok { DispatchQueue.main.async { self.loginMessage = "" } }
        }
    }

    func setStartupChime(_ on: Bool) {
        startupChime = on
        background {
            let r = Shell.admin("nvram StartupMute=\(on ? "%00" : "%01")")
            self.say(r.ok ? "Son de démarrage \(on ? "activé" : "désactivé") (effectif au prochain démarrage)." : "Annulé.")
            if !r.ok { DispatchQueue.main.async { self.startupChime = !on } }
        }
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let host = (trimmed.applyingTransform(.stripDiacritics, reverse: false) ?? trimmed)
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        background {
            let r = Shell.admin("scutil --set ComputerName \(Shell.quote(trimmed)) && scutil --set LocalHostName \(Shell.quote(host)) && scutil --set HostName \(Shell.quote(host))")
            self.say(r.ok ? "Le Mac s'appelle désormais « \(trimmed) » (\(host).local)." : "Annulé.")
        }
    }

    // MARK: Icônes d'apps

    func changeAppIcon(reset: Bool) {
        let appPanel = NSOpenPanel()
        appPanel.allowedContentTypes = [.application]
        appPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        appPanel.prompt = "Choisir l'app"
        guard appPanel.runModal() == .OK, let app = appPanel.url else { return }
        var image: NSImage?
        if !reset {
            let imgPanel = NSOpenPanel()
            imgPanel.allowedContentTypes = [.image, .icns]
            imgPanel.prompt = "Choisir l'icône"
            guard imgPanel.runModal() == .OK, let u = imgPanel.url, let img = NSImage(contentsOf: u) else { return }
            image = img
        }
        if NSWorkspace.shared.setIcon(image, forFile: app.path, options: []) {
            Shell.exec("/usr/bin/touch", [app.path])
            Mac.killall("Dock")
            message = reset ? "Icône d'origine restaurée pour \(app.deletingPathExtension().lastPathComponent)."
                            : "Nouvelle icône appliquée à \(app.deletingPathExtension().lastPathComponent)."
        } else {
            message = "Impossible de modifier cette app (app système ou protégée)."
        }
    }
}

struct CustomizeView: View {
    @ObservedObject var model: CustomizeModel
    @Local private var nameDraft = ""
    @Local private var loginDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Personnalisation", subtitle: "Apparence, Dock, coins actifs, démarrage…",
                       icon: "paintbrush.fill", color: .pink)
            if let m = model.message {
                Label(m, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }
            Form {
                Section("Apparence") {
                    Picker("Thème", selection: Binding(get: { model.style }, set: { model.setStyle($0) })) {
                        Text("Clair").tag(0); Text("Sombre").tag(1); Text("Automatique").tag(2)
                    }.pickerStyle(.segmented)
                    LabeledContent("Couleur d'accentuation") {
                        HStack(spacing: 8) {
                            ForEach(CustomizeModel.accents, id: \.value) { a in
                                Button { model.setAccent(a.value) } label: {
                                    Circle()
                                        .fill(a.value == -2 ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center)) : AnyShapeStyle(a.color))
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(Color.primary, lineWidth: model.accent == a.value ? 2 : 0).padding(-3))
                                }
                                .buttonStyle(.plain).help(a.name)
                            }
                        }
                    }
                    LabeledContent("Fond d'écran") {
                        HStack {
                            if let w = model.wallpaper, let img = NSImage(contentsOf: w) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Button("Choisir une image…") { model.chooseWallpaper() }
                        }
                    }
                }

                Section("Dock") {
                    LabeledContent("Taille des icônes") {
                        Slider(value: $model.dockSize, in: 16...128, step: 4, onEditingChanged: { if !$0 { model.applyDock() } })
                            .frame(width: 240)
                    }
                    Toggle("Agrandissement au survol", isOn: Binding(get: { model.dockMagnify }, set: { model.dockMagnify = $0; model.applyDock() }))
                    if model.dockMagnify {
                        LabeledContent("Taille agrandie") {
                            Slider(value: $model.dockLarge, in: 32...128, step: 4, onEditingChanged: { if !$0 { model.applyDock() } })
                                .frame(width: 240)
                        }
                    }
                    Picker("Position", selection: Binding(get: { model.dockPosition }, set: { model.dockPosition = $0; model.applyDock() })) {
                        Text("Gauche").tag("left"); Text("En bas").tag("bottom"); Text("Droite").tag("right")
                    }.pickerStyle(.segmented)
                    Picker("Effet de réduction", selection: Binding(get: { model.minEffect }, set: { model.minEffect = $0; model.applyDock() })) {
                        Text("Génie").tag("genie"); Text("Échelle").tag("scale"); Text("Aspiration").tag("suck")
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("Séparateurs entre les apps")
                        Spacer()
                        Button("Ajouter un espace") { model.addDockSpacer(small: false) }
                        Button("Ajouter un petit espace") { model.addDockSpacer(small: true) }
                    }
                }

                Section("Coins actifs") {
                    Grid(horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow { cornerPicker(0, "↖︎ Haut gauche"); cornerPicker(1, "↗︎ Haut droit") }
                        GridRow { cornerPicker(2, "↙︎ Bas gauche"); cornerPicker(3, "↘︎ Bas droit") }
                    }
                }

                Section {
                    LabeledContent("Espacement des icônes") {
                        HStack {
                            Slider(value: $model.menuSpacing, in: 0...16, step: 1).frame(width: 200)
                            Text(model.menuSpacing == 0 ? "Défaut" : "\(Int(model.menuSpacing))").monospacedDigit().frame(width: 50)
                            Button("Appliquer") { model.applyMenuSpacing() }
                        }
                    }
                } header: {
                    Text("Barre des menus")
                } footer: {
                    Text("Réduire l'espacement permet d'afficher plus d'icônes, notamment sur les MacBook à encoche.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Nom du Mac") {
                        HStack {
                            TextField("", text: $nameDraft).frame(width: 220)
                            Button("Renommer") { model.rename(nameDraft) }.disabled(nameDraft == model.computerName || nameDraft.isEmpty)
                        }
                    }
                    LabeledContent("Message sur l'écran de verrouillage") {
                        HStack {
                            TextField("Ex. : Si trouvé, appelez le 06…", text: $loginDraft).frame(width: 260)
                            Button("Appliquer") { model.applyLoginMessage(loginDraft) }.disabled(loginDraft.isEmpty)
                            Button("Retirer") { loginDraft = ""; model.applyLoginMessage(nil) }.disabled(model.loginMessage.isEmpty)
                        }
                    }
                    Toggle("Son de démarrage (« boot chime »)", isOn: Binding(get: { model.startupChime }, set: { model.setStartupChime($0) }))
                    LabeledContent {
                        HStack {
                            Button("Changer…") { model.changeAppIcon(reset: false) }
                            Button("Restaurer l'originale…") { model.changeAppIcon(reset: true) }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Icône d'une application")
                            Text("Une mise à jour de l'app peut rétablir son icône d'origine.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Identité et démarrage")
                } footer: {
                    Text("Le nom, le message et le son de démarrage demandent le mot de passe administrateur.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(!model.loaded)
        }
        .onAppear { if !model.loaded { model.load() } }
        .onChange(of: model.loaded) { _, _ in
            nameDraft = model.computerName
            loginDraft = model.loginMessage
        }
    }

    private func cornerPicker(_ i: Int, _ title: String) -> some View {
        Picker(title, selection: Binding(get: { model.corners[i] }, set: { model.setCorner(i, $0) })) {
            ForEach(CustomizeModel.cornerActions, id: \.0) { Text($0.1).tag($0.0) }
        }
    }
}
