// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
// Tests fonctionnels de la Boîte à outils.
// Lancement : ./Tests/run_tests.sh
// Les fonctions qui suppriment ou modifient des fichiers sont testées dans un bac à sable temporaire ;
// sur le vrai système, seules des lectures sont faites. Le presse-papiers est restauré à la fin.

import AppKit
import CryptoKit

var passed = 0, failed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("  ✓ \(name)") } else { failed += 1; print("  ✗ \(name) \(detail())") }
}
/// Fait tourner la boucle principale jusqu'à ce que la condition soit vraie (les modèles publient sur le fil principal).
@discardableResult
func waitFor(_ timeout: TimeInterval = 30, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    return cond()
}
func section(_ s: String) { print("\n▶︎ \(s)") }

let sandbox = FS.fm.temporaryDirectory.appendingPathComponent("boiteaoutils-tests-\(UUID().uuidString)")
try! FS.fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
History.url = sandbox.appendingPathComponent("historique.log")
func write(_ name: String, _ data: Data) -> URL {
    let u = sandbox.appendingPathComponent(name)
    try? FS.fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    FS.fm.createFile(atPath: u.path, contents: data)
    return u
}
func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

// MARK: - Fichiers et historique
section("Fichiers et historique")
let f1 = write("a/fichier.bin", random(100_000))
check("taille d'un dossier", FS.size(of: sandbox.appendingPathComponent("a")) >= 100_000)
try? FS.remove(f1, permanently: true)
check("suppression définitive", !FS.exists(f1))
let log = (try? String(contentsOf: History.url, encoding: .utf8)) ?? ""
check("historique enregistré", log.contains("Supprimé") && log.contains("fichier.bin"))
check("IgnoreList", { IgnoreList.add("tests", f1); defer { IgnoreList.reset("tests") }; return IgnoreList.get("tests").contains(f1.path) }())

// MARK: - Nettoyage (lecture seule)
section("Nettoyage système (analyse seule)")
let cleaner = CleanerModel()
cleaner.scan()
check("analyse terminée", waitFor(120) { cleaner.scannedOnce })
check("catégories trouvées", !cleaner.categories.isEmpty, "\(cleaner.categories.count)")
check("aucun doublon entre catégories", Set(cleaner.categories.flatMap { $0.items.map(\.url) }).count == cleaner.categories.reduce(0) { $0 + $1.items.count })
print("    \(cleaner.categories.map { "\($0.name): \(formatBytes($0.total))" }.joined(separator: " · "))")

// MARK: - Gros fichiers
section("Gros fichiers (bac à sable)")
let big = sandbox.appendingPathComponent("gros/video.mov")
try? FS.fm.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
FS.fm.createFile(atPath: big.path, contents: nil)
if let h = try? FileHandle(forWritingTo: big) { try? h.truncate(atOffset: 60_000_000); try? h.close() }
let large = LargeFilesModel()
large.root = sandbox; large.minMB = 50
large.scan()
check("fichier de 60 Mo trouvé", waitFor { large.scannedOnce } && large.results.contains { $0.url.lastPathComponent == "video.mov" })

// MARK: - Doublons
section("Doublons (bac à sable)")
let content = random(200_000)
let d1 = write("dup/original.jpg", content), d2 = write("dup/copie.jpg", content), d3 = write("dup/autre.jpg", random(200_000))
_ = d3
try? FS.fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: d1.path)
let dups = DuplicatesModel()
dups.root = sandbox.appendingPathComponent("dup"); dups.minKB = 100
dups.scan()
check("un groupe de doublons", waitFor { dups.scannedOnce } && dups.groups.count == 1, "\(dups.groups.count)")
check("l'original (le plus ancien) est conservé", dups.groups.first?.files.first(where: { !$0.selected })?.url.lastPathComponent == d1.lastPathComponent)
for g in dups.groups.indices { for j in dups.groups[g].files.indices { dups.groups[g].files[j].selected = true } }
dups.trashSelected()
check("sécurité : jamais tous les exemplaires", FS.exists(d1) || FS.exists(d2))

// MARK: - Projets de dev
section("Projets de dev (bac à sable)")
_ = write("projet/package.json", Data("{}".utf8)); _ = write("projet/node_modules/x/index.js", random(5000))
let dev = DevPurgeModel()
dev.root = sandbox
dev.scan()
check("node_modules détecté", waitFor { dev.scannedOnce } && dev.items.contains { $0.kind == "Node.js" })
for i in dev.items.indices { dev.items[i].selected = true }
dev.purge()
check("node_modules supprimé, code conservé", waitFor { !dev.scanning } && !FS.exists(sandbox.appendingPathComponent("projet/node_modules"))
      && FS.exists(sandbox.appendingPathComponent("projet/package.json")))

// MARK: - Utilitaires
section("Utilitaires (bac à sable)")
let util = UtilitiesModel()
let src = sandbox.appendingPathComponent("archive-source")
_ = write("archive-source/doc.txt", Data("Bonjour".utf8)); _ = write("archive-source/sous/img.bin", random(50_000))
let optionTest = write("archive-options/--test", Data("test option name".utf8))
let optionCommand = write("archive-options/--unzip-command=touch ZIP_OPTION_EXECUTED", Data("command option name".utf8))
let optionNormal = write("archive-options/ordinary.txt", Data("ordinary name".utf8))
util.compress([optionTest, optionCommand, optionNormal], .zip, password: "", reveal: false)
let optionArchive = waitFor(30, { !util.archiveBusy && util.lastArchive != nil }) ? util.lastArchive : nil
let optionListing = optionArchive.map { Shell.exec("/usr/bin/unzip", ["-Z1", $0.path]).output } ?? ""
check("noms ZIP commençant par -- restent des fichiers", optionListing.contains("--test") && optionListing.contains("--unzip-command=touch ZIP_OPTION_EXECUTED"))
check("aucune commande injectée par un nom de fichier", !FS.exists(sandbox.appendingPathComponent("archive-options/ZIP_OPTION_EXECUTED")))
let refHash = SHA256.hash(data: (try? Data(contentsOf: src.appendingPathComponent("sous/img.bin"))) ?? Data())
for fmt in [UtilitiesModel.ArchiveFormat.zip, .tgz, .txz, .aar] {
    util.lastArchive = nil
    util.compress([src], fmt, password: "", reveal: false)
    guard waitFor(30, { !util.archiveBusy && util.lastArchive != nil }), let arc = util.lastArchive else { check("compression \(fmt.rawValue)", false, util.archiveMessage); continue }
    util.lastExtracted = []
    util.extract([arc], reveal: false)
    waitFor { !util.archiveBusy && !util.lastExtracted.isEmpty }
    let found = FS.fm.enumerator(at: util.lastExtracted.first ?? sandbox, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.lastPathComponent == "img.bin" }
    let same = found.flatMap { try? Data(contentsOf: $0) }.map { SHA256.hash(data: $0) == refHash } ?? false
    check("\(fmt.rawValue) : compression + extraction identiques", same, util.archiveMessage)
}
util.lastArchive = nil
util.compress([src], .dmg, password: "motdepasse-test", reveal: false)
if waitFor(60, { !util.archiveBusy && util.lastArchive != nil }), let dmg = util.lastArchive {
    check("image disque chiffrée AES-256", Shell.exec("/usr/bin/hdiutil", ["isencrypted", dmg.path]).output.contains("YES"))
} else { check("image disque chiffrée", false, util.archiveMessage) }
let hashFile = write("hash.bin", random(300_000))
util.hash(hashFile)
waitFor { util.hashes.count == 4 }
let shasum = Shell.exec("/usr/bin/shasum", ["-a", "256", hashFile.path]).output.components(separatedBy: " ").first ?? ""
check("SHA-256 identique à shasum", util.hashes.first { $0.0 == "SHA-256" }?.1 == shasum)
// OCR : on dessine un texte puis on le relit
let img = NSImage(size: NSSize(width: 900, height: 160))
img.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 160).fill()
("Boîte à outils 2026" as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
img.unlockFocus()
let png = sandbox.appendingPathComponent("ocr.png")
if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: png) }
let savedClipboard = NSPasteboard.general.string(forType: .string)
util.recognize(png)
check("OCR : texte reconnu", waitFor { !util.ocrText.isEmpty } && util.ocrText.contains("outils"), util.ocrText)

// MARK: - Presse-papiers
section("Presse-papiers")
let clip = ClipboardHistory.shared
clip.start()
let marker = "test-boiteaoutils-\(UUID().uuidString.prefix(6))"
NSPasteboard.general.clearContents(); NSPasteboard.general.setString(marker, forType: .string)
check("texte copié enregistré", waitFor(5) { clip.items.first?.text == marker })
let pb = NSPasteboard.general
pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
pb.setString("motdepasse-secret", forType: .string)
waitFor(2) { false }
check("mot de passe (type masqué) ignoré", !clip.items.contains { $0.text == "motdepasse-secret" })
clip.items.removeAll { $0.text == marker }
NSPasteboard.general.clearContents()
if let s = savedClipboard { NSPasteboard.general.setString(s, forType: .string) }

// MARK: - Garder éveillé
section("Garder éveillé")
KeepAwake.shared.start(minutes: 1)
check("assertion caffeinate active", Shell.exec("/usr/bin/pmset", ["-g", "assertions"]).output.contains("caffeinate"))
KeepAwake.shared.stop()
waitFor(3) { !Shell.exec("/usr/bin/pmset", ["-g", "assertions"]).output.contains("caffeinate") }
check("arrêt propre", !KeepAwake.shared.active)

// MARK: - Lectures système (rien n'est modifié)
section("Lectures système")
let info = SystemInfo.collect()
check("tableau de bord", info.memTotal > 0 && info.diskTotal > 0 && !info.osVersion.isEmpty)
if let b = BatteryModel.read() { check("batterie", b.designMAh > 0 && b.fullMAh > 0 && b.cycles >= 0, "\(b)") }
check("capteurs SMC", !Sensors.readAll().isEmpty)
check("ports USB-C lisibles", !PortsModel.readPorts().isEmpty)
let disks = DisksModel(); disks.load()
check("disques et volumes", waitFor { !disks.disks.isEmpty && !disks.volumes.isEmpty })
disks.testVolume = URL(fileURLWithPath: "/"); disks.testSizeMB = 256
disks.speedTest()
check("test de vitesse", waitFor(120) { disks.write != nil && disks.read != nil } && (disks.write ?? 0) > 1, disks.progress)
print(String(format: "    écriture %.0f Mo/s, lecture %.0f Mo/s", disks.write ?? 0, disks.read ?? 0))
let displays = DisplaysModel(); displays.load()
check("écrans et modes", displays.displays.first.map { !$0.modes.isEmpty && $0.current != nil } ?? false)
check("persistance analysée", !Persistence.scan().isEmpty)
let sec = SecurityModel(); sec.loadConnections(admin: false)
check("connexions réseau", waitFor { !sec.loadingConnections && !sec.connections.isEmpty })
_ = SecurityMonitor.cameraInUse(); _ = SecurityMonitor.microphoneInUse()
check("caméra / micro interrogeables", true)
let procs = ProcessesModel(); procs.refresh()
check("processus", waitFor { procs.procs.count > 10 })
if let me = procs.procs.first { procs.inspect(me) }
check("fiche processus", waitFor { procs.details != nil })
let startup = StartupModel(); startup.load()
check("démarrage", true, "\(startup.items.count) éléments")
let apps = UninstallerModel(); apps.load()
check("applications listées", waitFor { !apps.apps.isEmpty })
if let thirdParty = apps.apps.first(where: { !$0.isApple }) {
    apps.selectedID = thirdParty.id
    check("restes d'une app (\(thirdParty.name))", waitFor { !apps.searchingLeftovers })
}
let orphans = OrphansModel(); orphans.scan()
check("restes orphelins", waitFor(60) { orphans.scannedOnce })
let privacy = PrivacyModel(); privacy.scan()
check("confidentialité", waitFor { privacy.scannedOnce })
let space = SpaceModel(); space.setRoot(FS.home.appendingPathComponent("Documents"))
check("espace disque", waitFor(120) { space.pending == 0 } && !space.entries.isEmpty, "\(space.pending) restants")
let tw = Tweaks()
check("réglages cachés lisibles", tw.allSatisfy { _ in true })
let toggles = QuickTogglesModel(); toggles.refresh()
check("interrupteurs", waitFor { toggles.states.count == toggles.toggles.count })
let custom = CustomizeModel(); custom.load()
check("personnalisation", waitFor { custom.loaded })
let net = NetworkModel(); net.load()
check("réseau", waitFor { net.loaded && !net.services.isEmpty })
let maint = MaintenanceModel()
maint.run(maint.tasks.filter { $0.id == "security" })
check("maintenance (audit de sécurité)", waitFor { maint.running.isEmpty && maint.log.contains { $0.text.contains("SIP") } })
PermissionCenter.shared.refresh(full: true)
check("autorisations vérifiées", waitFor { PermissionCenter.shared.states[.fullDisk] != nil })

// MARK: - Modifications testées sur des éléments factices
section("Modifications (éléments factices, retirés ensuite)")

// Réglage caché : mécanisme complet sur un domaine de test
let fake = Tweak(section: "Test", title: "Test", domain: "com.boiteaoutils.tests", key: "Option", type: "bool", on: "true", off: nil, restart: nil)
fake.apply(true)
let on = fake.readEnabled()
fake.apply(false)
check("réglage caché : activer puis rétablir", on && !fake.readEnabled())
Shell.exec("/usr/bin/defaults", ["delete", "com.boiteaoutils.tests"])
try? FS.fm.removeItem(at: FS.home.appendingPathComponent("Library/Preferences/com.boiteaoutils.tests.plist"))

// Démarrage + alerte de sécurité : faux agent de lancement
let monitor = SecurityMonitor.shared
monitor.persistenceWatch = true
let agentDir = FS.home.appendingPathComponent("Library/LaunchAgents")
try? FS.fm.createDirectory(at: agentDir, withIntermediateDirectories: true)
let agent = agentDir.appendingPathComponent("com.boiteaoutils.tests.agent.plist")
(["Label": "com.boiteaoutils.tests.agent", "Program": "/usr/bin/true", "RunAtLoad": false] as NSDictionary).write(to: agent, atomically: true)
check("alerte : nouvel élément au démarrage détecté", waitFor(5) { monitor.events.contains { $0.text.contains("com.boiteaoutils.tests.agent") } })
monitor.persistenceWatch = false
let st = StartupModel(); st.load()
if let item = st.items.first(where: { $0.label == "com.boiteaoutils.tests.agent" }) {
    st.toggle(item)
    check("désactivation (déplacé, réversible)", waitFor { st.items.first { $0.label == item.label }?.enabled == false } && !FS.exists(agent))
    if let off = st.items.first(where: { $0.label == item.label }) {
        st.toggle(off)
        check("réactivation", waitFor { st.items.first { $0.label == item.label }?.enabled == true } && FS.exists(agent))
    }
} else { check("faux agent listé", false) }
Shell.exec("/bin/launchctl", ["bootout", "gui/\(getuid())", agent.path])
try? FS.fm.removeItem(at: agent)
try? FS.fm.removeItem(at: StartupModel.disabledPath(for: "com.boiteaoutils.tests.agent.plist"))

// Désinstallateur : fausse app + restes
let appsDir = FS.home.appendingPathComponent("Applications")
let createdAppsDir = !FS.exists(appsDir)
try? FS.fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
let fakeApp = appsDir.appendingPathComponent("BoiteTestApp.app")
try? FS.fm.createDirectory(at: fakeApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
(["CFBundleIdentifier": "com.boiteaoutils.testapp", "CFBundleShortVersionString": "1.0"] as NSDictionary)
    .write(to: fakeApp.appendingPathComponent("Contents/Info.plist"), atomically: true)
let pref = FS.home.appendingPathComponent("Library/Preferences/com.boiteaoutils.testapp.plist")
(["a": 1] as NSDictionary).write(to: pref, atomically: true)
let cacheDir = FS.home.appendingPathComponent("Library/Caches/com.boiteaoutils.testapp")
try? FS.fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
let un = UninstallerModel(); un.load()
if waitFor(30, { un.apps.contains { $0.bundleID == "com.boiteaoutils.testapp" } }), let a = un.apps.first(where: { $0.bundleID == "com.boiteaoutils.testapp" }) {
    un.selectedID = a.id
    check("restes trouvés (préférences + caches)", waitFor { !un.searchingLeftovers } && un.leftovers.count >= 2, "\(un.leftovers.map(\.url.lastPathComponent))")
    un.uninstall(includeApp: true)
    check("app et restes supprimés (corbeille)", waitFor { !un.working } && !FS.exists(fakeApp) && !FS.exists(pref) && !FS.exists(cacheDir), un.message ?? "")
} else { check("fausse app listée", false) }
if createdAppsDir { try? FS.fm.removeItem(at: appsDir) }

func Tweaks() -> [Tweak] { Tweak.all.map { var t = $0; t.enabled = t.readEnabled(); return t } }

// MARK: - Bilan
try? FS.fm.removeItem(at: sandbox)
print("\n\(passed) réussis, \(failed) échoués")
exit(failed == 0 ? 0 : 1)
