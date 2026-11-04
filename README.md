<p align="center"><img src="docs/icon.png" width="110" alt="Icône de Clair"></p>
<h1 align="center">Clair</h1>
<p align="center"><strong>Désinstalle tes applications Mac, sans laisser de traces.</strong></p>
<p align="center">
  <a href="https://github.com/sergefavy/clair/releases/latest"><img src="https://img.shields.io/github/v/release/sergefavy/clair?color=29a887&amp;label=Télécharger" alt="Dernière version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-24292f" alt="macOS 14 et plus">
  <a href="https://github.com/sergefavy/clair/actions/workflows/ci.yml"><img src="https://github.com/sergefavy/clair/actions/workflows/ci.yml/badge.svg" alt="Tests"></a>
</p>

Quand on glisse une application dans la Corbeille, macOS garde ses préférences, caches, conteneurs, services de démarrage, outils privilégiés et reçus d'installation. Clair les retrouve et les met à la Corbeille avec l'application.

## Fonctionnalités

- **Désinstallation complète** : choisis une app dans la liste ou glisse-la dans la fenêtre. Clair analyse aussitôt et coche ce qui lui appartient avec certitude.
- **En profondeur** : `~/Library` (données, caches, préférences, conteneurs, journaux, stockage web, rapports de plantage…), caches système `/var/folders`, et `/Library` (services `LaunchDaemons`/`LaunchAgents`, `PrivilegedHelperTools`, pilotes audio et caméra) ; reçus `pkgutil` compris.
- **Restes d'applications déjà supprimées** : l'onglet *Restes* repère les fichiers dont l'identifiant ne correspond plus à aucune application ni aucun plugin installés.
- **Apps protégées par le système** (installées par un `.pkg`, comme Zoom ou Teams) : le Finder s'en charge et macOS demande ton mot de passe. Les services sont arrêtés avant d'être retirés.
- **Réversible** : tout va dans la Corbeille. Clair ne la vide jamais.
- **Prudent** : les correspondances incertaines restent décochées. Les apps Apple, les extensions système et les chemins qui contiennent des liens symboliques sont protégés. Chaque élément est revérifié juste avant d'être déplacé.
- Journal local des opérations. Sans compte, sans réseau.

## Installation

Télécharge la [dernière version](https://github.com/sergefavy/clair/releases/latest), ouvre le DMG et glisse **Clair** dans **Applications**. L'app est signée localement (pas de notarisation Apple). Au premier lancement, fais un clic droit sur Clair › **Ouvrir**.

Au premier nettoyage d'un élément protégé, macOS te demande d'autoriser Clair à piloter le Finder. Accepte : c'est ce qui lui permet de déplacer ces éléments.

## Développement

Swift 6, SwiftUI, aucune dépendance.

```sh
swift run ClairChecks      # contrôles du moteur sur des fichiers fictifs
zsh scripts/build.sh       # construit build/Clair.app
zsh scripts/make-release.sh  # DMG, ZIP et empreintes
```

Analyse en lecture seule depuis le terminal :

```sh
build/Clair.app/Contents/MacOS/Clair --analyser "/Applications/Nom.app"
build/Clair.app/Contents/MacOS/Clair --restes
```

| Dossier | Contenu |
| --- | --- |
| `Sources/Core` | Moteur : emplacements, identification, analyse, restes, suppression |
| `Sources/App` | Interface SwiftUI et opérations système (Finder, `launchctl`, admin) |
| `Tests` | Contrôles exécutables sur des fichiers fictifs |

Détails du fonctionnement : [docs/GUIDE.md](docs/GUIDE.md).
