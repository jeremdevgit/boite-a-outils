# Sécurité

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
