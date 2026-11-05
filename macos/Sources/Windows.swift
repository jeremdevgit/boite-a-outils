// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import Carbon
import ApplicationServices

/// Rangement des fenêtres au clavier (inspiré de Rectangle). Raccourcis globaux ⌃⌥ + touche.
final class WindowSnapper: ObservableObject {
    static let shared = WindowSnapper()

    enum Action: Int, CaseIterable {
        case left, right, top, bottom, maximize, center, topLeft, topRight, bottomLeft, bottomRight

        var title: String {
            switch self {
            case .left: "Moitié gauche"
            case .right: "Moitié droite"
            case .top: "Moitié haute"
            case .bottom: "Moitié basse"
            case .maximize: "Plein écran (agrandir)"
            case .center: "Centrer"
            case .topLeft: "Quart haut gauche"
            case .topRight: "Quart haut droit"
            case .bottomLeft: "Quart bas gauche"
            case .bottomRight: "Quart bas droit"
            }
        }

        var key: (code: Int, label: String) {
            switch self {
            case .left: (kVK_LeftArrow, "←")
            case .right: (kVK_RightArrow, "→")
            case .top: (kVK_UpArrow, "↑")
            case .bottom: (kVK_DownArrow, "↓")
            case .maximize: (kVK_Return, "↩")
            case .center: (kVK_ANSI_C, "C")
            case .topLeft: (kVK_ANSI_U, "U")
            case .topRight: (kVK_ANSI_I, "I")
            case .bottomLeft: (kVK_ANSI_J, "J")
            case .bottomRight: (kVK_ANSI_K, "K")
            }
        }

        /// Cadre cible dans les coordonnées Cocoa (origine en bas à gauche).
        func frame(in v: CGRect, current: CGSize) -> CGRect {
            let w = v.width / 2, h = v.height / 2
            switch self {
            case .left: return CGRect(x: v.minX, y: v.minY, width: w, height: v.height)
            case .right: return CGRect(x: v.midX, y: v.minY, width: w, height: v.height)
            case .top: return CGRect(x: v.minX, y: v.midY, width: v.width, height: h)
            case .bottom: return CGRect(x: v.minX, y: v.minY, width: v.width, height: h)
            case .maximize: return v
            case .center:
                let s = CGSize(width: min(current.width, v.width), height: min(current.height, v.height))
                return CGRect(x: v.midX - s.width / 2, y: v.midY - s.height / 2, width: s.width, height: s.height)
            case .topLeft: return CGRect(x: v.minX, y: v.midY, width: w, height: h)
            case .topRight: return CGRect(x: v.midX, y: v.midY, width: w, height: h)
            case .bottomLeft: return CGRect(x: v.minX, y: v.minY, width: w, height: h)
            case .bottomRight: return CGRect(x: v.midX, y: v.minY, width: w, height: h)
            }
        }
    }

    @Published var enabled = UserDefaults.standard.bool(forKey: "windowSnapping") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "windowSnapping")
            enabled ? register() : unregister()
        }
    }
    @Published var trusted = AXIsProcessTrusted()

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { WindowSnapper.shared.perform(Int(hk.id)) }
            return noErr
        }, 1, &spec, nil, &handler)
        for a in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x42414F54), id: UInt32(a.rawValue))   // « BAOT »
            RegisterEventHotKey(UInt32(a.key.code), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    func unregister() {
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    func perform(_ raw: Int) {
        guard let action = Action(rawValue: raw) else { return }
        trusted = AXIsProcessTrusted()
        guard trusted else { requestAccess(); return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = value as! AXUIElement      // type vérifié juste au-dessus

        var pos = CGPoint.zero, size = CGSize.zero
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return }
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        // L'accessibilité utilise une origine en haut à gauche de l'écran principal ; Cocoa en bas à gauche.
        guard let primary = NSScreen.screens.first else { return }
        let H = primary.frame.height
        let center = CGPoint(x: pos.x + size.width / 2, y: H - (pos.y + size.height / 2))
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? primary
        let target = action.frame(in: screen.visibleFrame, current: size)

        var newPos = CGPoint(x: target.minX, y: H - target.maxY)
        var newSize = target.size
        if let s = AXValueCreate(.cgSize, &newSize), let p = AXValueCreate(.cgPoint, &newPos) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        }
    }
}

struct WindowsView: View {
    @ObservedObject var snapper = WindowSnapper.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Fenêtres", subtitle: "Rangez vos fenêtres au clavier : moitiés, quarts, plein écran",
                       icon: "rectangle.split.2x2.fill", color: .indigo) {
                Toggle("Activer les raccourcis", isOn: $snapper.enabled).toggleStyle(.switch)
            }
            Form {
                Section {
                    if snapper.trusted {
                        Label("Autorisation d'accessibilité accordée.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("Pour déplacer les fenêtres des autres apps, autorisez la Boîte à outils dans Accessibilité.",
                                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Spacer()
                            Button("Autoriser…") { snapper.requestAccess() }
                            Button("Revérifier") { snapper.trusted = AXIsProcessTrusted() }
                        }
                    }
                } footer: {
                    Text("Réglages Système › Confidentialité et sécurité › Accessibilité. Après une mise à jour de l'app, il peut être nécessaire de la retirer puis de l'ajouter à nouveau.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Raccourcis (⌃ Contrôle + ⌥ Option + touche)") {
                    ForEach(WindowSnapper.Action.allCases, id: \.rawValue) { a in
                        HStack(spacing: 14) {
                            preview(a)
                            Text(a.title)
                            Spacer()
                            Text("⌃⌥\(a.key.label)").font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                            Button("Tester") { NSApp.hide(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { snapper.perform(a.rawValue) } }
                                .controlSize(.small).help("Applique l'action à la fenêtre située derrière")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { snapper.trusted = AXIsProcessTrusted() }
    }

    /// Mini-schéma de l'emplacement de la fenêtre.
    private func preview(_ a: WindowSnapper.Action) -> some View {
        let box = CGRect(x: 0, y: 0, width: 36, height: 24)
        let f = a.frame(in: box, current: CGSize(width: 20, height: 14))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).stroke(Color.secondary, lineWidth: 1)
            RoundedRectangle(cornerRadius: 2).fill(Color.indigo)
                .frame(width: f.width - 2, height: f.height - 2)
                .offset(x: f.minX + 1, y: box.height - f.maxY + 1)
        }
        .frame(width: box.width, height: box.height)
    }
}
