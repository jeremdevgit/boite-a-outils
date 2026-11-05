# Historique des versions

## Windows 2.2.0 et macOS 1.5 — 2026-11-05 — Publication open source

- Code publié sous licence GNU GPL v3 ou ultérieure.
- Nouvelle page **Mes logiciels** (Windows et macOS) : les autres logiciels de l'auteur, avec le lien de téléchargement officiel ; crédit « jeremdevgit » dans l'application, l'installateur et les propriétés du fichier.
- **Installateur macOS** : l'ancienne version est fermée et retirée automatiquement avant l'installation ; installateurs produits dans `dist/` avec leurs empreintes SHA-256.
- **Windows** : l'installateur n'embarque plus les autres logiciels (téléchargement depuis leur page officielle) ; l'interface n'ouvre que des adresses d'une liste fixe, toujours sans droits administrateur.
- Versions Windows construites par GitHub Actions, avec contrôle automatique (aucun chemin ni identifiant de la machine de construction, aucune dépendance au Runtime Visual C++).

## Windows 2.1.0 — macOS 1.4

- Désinstallation automatique de la version précédente par l'installateur Windows (y compris une version installée ailleurs) ; historique et réglages conservés.
- Barre des tâches transparente, Mode Dieu, tests de stabilité, diagnostic avancé, ports USB et câbles, capteurs (Windows).
- Câbles & ports, capteurs, disques, écrans, sécurité, utilitaires, autorisations (macOS).
