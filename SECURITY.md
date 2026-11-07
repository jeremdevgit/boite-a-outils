# Security

**English** · [Français](#sécurité)

## Reporting a vulnerability

Please **do not** open a public issue for a security flaw.
Use GitHub's private reporting: the repository's **Security** tab → **Report a vulnerability**.
Describe the problem, the version affected, the steps to reproduce it and, if possible, a suggested fix.
You will get an answer as soon as possible; the fix will ship in a new release, crediting you if you agree.

## Supported versions

Only the latest release (*Releases* page) receives fixes.

## What the software guarantees

- No data is sent: no telemetry, no account.
- Windows: installed in a folder that only administrators can modify; system libraries loaded from System32 only; the interface can only open addresses taken from a fixed list; links opened without administrator rights.
- macOS: the installer package always installs into /Applications, owned by the system (root).

## Out of scope

- Boîte à outils runs with administrator rights to change Windows: malware that is already administrator on the machine isn't a scenario it can protect against.
- The executables aren't signed with a paid certificate (SmartScreen / Gatekeeper warning): check the SHA-256 hash published with each release.

---

# Sécurité

[English](#security) · **Français**

## Signaler une vulnérabilité

Merci de **ne pas** ouvrir de ticket public pour une faille de sécurité.
Utilise le signalement privé de GitHub : onglet **Security** du dépôt → **Report a vulnerability**.
Décris le problème, la version concernée, les étapes pour le reproduire et, si possible, une piste de correction.
Tu recevras une réponse dès que possible ; la correction sera publiée dans une nouvelle version, avec ton accord pour être cité.

## Versions suivies

Seule la dernière version publiée (page *Releases*) reçoit des correctifs.

## Ce que garantit le logiciel

- Aucune donnée n'est envoyée : pas de télémétrie, pas de compte.
- Windows : installation dans un dossier modifiable uniquement par les administrateurs ; bibliothèques système chargées depuis System32 uniquement ; l'interface ne peut ouvrir que des adresses tirées d'une liste fixe ; liens ouverts sans droits administrateur.
- macOS : paquet d'installation qui installe toujours dans /Applications, appartenant au système (root).

## Hors périmètre

- La Boîte à outils fonctionne avec les droits administrateur pour modifier Windows : un logiciel malveillant déjà administrateur sur la machine n'est pas un scénario contre lequel elle peut protéger.
- Les exécutables ne sont pas signés par un certificat payant (avertissement SmartScreen / Gatekeeper) : vérifie l'empreinte SHA-256 publiée avec chaque version.
