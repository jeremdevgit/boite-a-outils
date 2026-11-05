# Boîte à outils — macOS

Application SwiftUI native pour entretenir son Mac (inspirée de CleanMyMac).

## Modules
| Module | Rôle |
|---|---|
| Tableau de bord | Disque, mémoire, CPU, batterie, sécurité (SIP, Gatekeeper, FileVault, pare-feu), recommandations, analyse intelligente |
| Nettoyage système | Caches, journaux, états de fenêtres, fichiers Xcode/npm/Gradle, corbeille, pièces jointes Mail, sauvegardes iOS, vieux téléchargements |
| Espace disque | Explorateur de la taille des dossiers (façon « Space Lens ») |
| Gros fichiers | Fichiers volumineux et/ou anciens |
| Doublons | Fichiers identiques (comparaison SHA-256), le plus ancien est conservé |
| Désinstallateur | Supprime une app et ses restes (préférences, caches, conteneurs, agents…) |
| Démarrage | Éléments d'ouverture + agents/daemons de lancement, désactivation réversible |
| Processus | Top CPU / mémoire, quitter ou forcer à quitter |
| Maintenance | DNS, purge RAM, instantanés Time Machine, Spotlight, permissions, « Ouvrir avec », Quick Look, polices, vérif. disque, Finder/Dock, corbeille, presse-papiers, audit sécurité |
| Mises à jour | macOS (softwareupdate), App Store, Homebrew |
| Confidentialité | Cache / historique / cookies de Safari, Chrome, Brave, Edge, Arc, Vivaldi, Opera, Firefox ; documents récents ; historique du Terminal ; miniatures Quick Look *(inspiré de CCleaner)* |
| Projets de dev | node_modules, Pods, target, .build, .gradle, venv, .next… projets inactifs > 30 j présélectionnés *(inspiré de Mole « purge »)* |
| Restes orphelins | Fichiers de la Bibliothèque appartenant à des apps désinstallées, apps iPhone/iPad sur Mac prises en compte *(inspiré de Pearcleaner)* |
| Réglages cachés | ~27 options `defaults` (Finder, Dock, captures d'écran, système) + raccourcis vers les utilitaires système cachés *(inspiré d'OnyX / TinkerTool)* |
| Historique | Journal de toutes les suppressions (`~/Library/Logs/BoiteAOutils/historique.log`) *(inspiré de Mole)* |
| Barre des menus | Moniteur CPU / RAM / disque / réseau / batterie *(inspiré de Stats)* — désactivable dans Réglages cachés |

| Interrupteurs | Garder éveillé (caffeinate), mode sombre, masquer le bureau, fichiers cachés, Wi-Fi, muet, économie d'énergie, actions rapides *(One Switch, Amphetamine)* |
| Personnalisation | Thème, couleur d'accentuation, fond d'écran, Dock (taille, position, séparateurs), coins actifs, espacement barre des menus, nom du Mac, message écran verrouillé, son de démarrage, icônes d'apps *(TinkerTool, MacPilot)* |
| Fenêtres | Rangement au clavier ⌃⌥ + flèches / ↩ / C / U I J K *(Rectangle)* — nécessite l'autorisation Accessibilité |
| Presse-papiers | Historique de 60 textes, épinglage, mots de passe ignorés *(Maccy)* |
| Réseau | DNS en un clic (Cloudflare, Quad9, AdGuard…), éditeur /etc/hosts, blocage de sites, IP, test de débit networkQuality *(SwitchHosts)* |

| Autorisations | Vérification en direct (accès disque, automatisation, accessibilité, gestion des apps, écran, notifications, connexion) + chemin le plus court pour chacune |
| Batterie | Santé (Apple + mesurée), mAh, cycles, tension, courant, température (SMC), chargeur, historique, AirPods/accessoires Bluetooth *(coconutBattery, AirBattery)* |
| Câbles & ports | État de chaque port USB-C, e-marker du câble (débit, W, EPR, certification), profils du chargeur, puissance en direct, diagnostic *(WhatCable, MIT)* |
| Capteurs | ~100 sondes de température SMC, ventilateurs, consommation, GPU *(Macs Fan Control, Stats)* |
| Disques | SMART, NVMe/TRIM, volumes, test de vitesse sans cache *(DriveDx, Blackmagic Disk Speed Test)* |
| Écrans | Résolutions dont HiDPI cachées avec retour auto, Hz, taille, ppp *(BetterDisplay)* |
| Sécurité | Persistance + signatures + VirusTotal, alertes démarrage / caméra / micro, connexions par app *(KnockKnock, BlockBlock, OverSight, LuLu, TaskExplorer)* |
| Utilitaires | OCR d'une zone de l'écran, pipette, archives (zip, 7z, rar… / DMG chiffré), empreintes *(Shottr, Keka)* |

Nettoyage système : catégorie « Installeurs inutiles » (.dmg, .pkg, Install macOS) et exclusions par clic droit.

## Sécurité
- Caches et journaux : suppression définitive (recréés automatiquement).
- Fichiers personnels, apps, doublons : **toujours à la corbeille**.
- Les actions système demandent le mot de passe administrateur via la fenêtre macOS standard.

## Confidentialité
- Tout est analysé **localement**. Aucune télémétrie, aucun compte, aucune donnée envoyée.
- Seules exceptions, toujours sur clic explicite : « Afficher l'IP publique » (api.ipify.org),
  « Rechercher sur VirusTotal » (envoie uniquement l'empreinte SHA-256 du fichier, dans le navigateur),
  et le test de débit (serveurs Apple via `networkQuality`).
- Données conservées sur le Mac de l'utilisateur uniquement : historique des suppressions
  (`~/Library/Logs/BoiteAOutils/`), historique de santé de la batterie et éléments désactivés
  (`~/Library/Application Support/BoiteAOutils/`), préférences et éléments épinglés du presse-papiers (préférences de l'app).
- Le binaire et les installateurs ne contiennent aucune donnée de la machine de compilation
  (chemins retirés via `-file-prefix-map`, attributs étendus effacés).

## Tests
```sh
./Tests/run_tests.sh   # 54 tests fonctionnels ; les suppressions sont testées dans un bac à sable
```

## Installation
Le paquet `.pkg` ferme l'application si elle est ouverte et retire l'ancienne version avant d'installer la nouvelle (réglages et historique conservés).

## Licences
Le décodage USB-PD et l'accès SMC sont adaptés de WhatCable (MIT, © 2026 Darryl Morley) —
voir `Resources/Licences.txt`, aussi affiché dans « À propos ».

## Compiler
```sh
./build.sh        # → build/Boîte à outils.app (Apple Silicon + Intel)
./make_installer.sh   # → dist/Boite-a-outils-<version>.dmg, .pkg et SHA256SUMS-macos.txt
```
Nécessite uniquement les Command Line Tools (`xcode-select --install`).

Pour une analyse complète : Réglages Système › Confidentialité et sécurité › Accès complet au disque › ajouter « Boîte à outils ».
