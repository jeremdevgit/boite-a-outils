# Historique des versions

## Windows 2.3.1 et macOS 1.6 — 2026-11-07 — Sécurité

- Chargement des traductions : chemins HTML constants ; lecture bornée des ressources de version et tableau réseau natif corrigé. Éditeur documenté dans EDITEUR.md.
- Translation loading uses constant paths; version resources are bounds-checked and flexible network-table access is corrected.
- Windows : rejet des chemins ambigus (`..`, noms de périphériques, flux alternatifs), résolution des chemins et rejet des jonctions/reparse points pour l'installation.
- Les droits réels des dossiers et de leurs parents sont vérifiés. Le propriétaire et la DACL sont explicitement protégés ; une erreur de protection arrête l'installation avant la copie des exécutables.
- Copie vers un fichier temporaire nouveau, puis protection et vérification avant remplacement.
- CI : Actions épinglées à des SHA, compilation en lecture seule et publication isolée avec droits d'écriture. Tests de régression Windows des ACL et jonctions.
- macOS reste en version 1.6, sans changement de binaire.

### English

- Windows: reject ambiguous install paths and reparse points; validate resolved paths and actual directory/parent permissions.
- Protect and verify ownership/DACLs; abort on security failures. Stage binaries in new files and verify permissions before replacement.
- Pin Actions to commit SHAs, isolate release write permissions and run native Windows security regression tests.
- macOS 1.6 binaries are unchanged.


## Windows 2.3.0 et macOS 1.6 — 2026-11-07

- Interface en huit langues : français, anglais, espagnol, allemand, italien, portugais, chinois simplifié et japonais ; choix automatique et sélecteur de langue.
- Nouvel onglet de recherche de fichiers et dossiers sur Windows/macOS : index local en mémoire, jokers, recherche dans le chemin, filtres taille/date/type, tri et copie du chemin.
- Windows : filtres de statut ou de taille dans Démarrage, Services, Processus, Applications, Sysinternals et Historique ; filtres par taille pour les installateurs et archives oubliés, sélection et désélection groupées dans les listes utiles. Les éléments masqués par un filtre sont décochés.
- macOS : sélection et désélection groupées dans Nettoyage, Gros fichiers et Restes d'applications.
- Traduction Windows : les valeurs dynamiques restent des nœuds texte, sans interprétation HTML.
- README en anglais, français et espagnol ; captures anglaises réalisées avec des données de démonstration.

### English

- Interface in eight languages: French, English, Spanish, German, Italian, Portuguese, Simplified Chinese and Japanese, with automatic detection and a language selector.
- New file/folder search tab on Windows/macOS: session-local index, wildcards, full-path matching, type/size/date filters, sorting and path copying.
- Windows: contextual filters in Startup, Services, Processes, Apps, Sysinternals and History; size filters for forgotten installers and archives, and bulk selection in relevant lists. Filtering clears hidden selections.
- macOS: select/deselect all in Cleanup, Large files and App leftovers.
- Windows translation: dynamic values stay in text nodes and are never interpreted as HTML.
- English, French and Spanish READMEs; English screenshots use demonstration data.

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
