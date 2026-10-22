<p align="center">
  <img src="docs/icon.png" width="110" alt="Icône de Clair">
</p>
<h1 align="center">Clair</h1>
<p align="center"><strong>Fais de la place. Garde la main.</strong></p>
<p align="center">Une application macOS native pour examiner les fichiers associés à tes applications<br>et confirmer chaque nettoyage.</p>
<p align="center">
  <a href="https://github.com/sergefavy/clair/releases/latest"><img src="https://img.shields.io/github/v/release/sergefavy/clair?color=36b38f&amp;label=Télécharger" alt="Dernière version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-24292f" alt="macOS 14 et plus">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-24292f" alt="Apple Silicon">
  <a href="https://github.com/sergefavy/clair/actions/workflows/ci.yml"><img src="https://github.com/sergefavy/clair/actions/workflows/ci.yml/badge.svg" alt="Tests et compilation"></a>
</p>
<p align="center"><a href="https://github.com/sergefavy/clair/releases/latest"><strong>Télécharger Clair pour Mac</strong></a> · <a href="docs/GUIDE.md">Guide d’utilisation</a> · <a href="https://github.com/sergefavy/clair/issues">Signaler un problème</a></p>

![Présentation de Clair](docs/banner.svg)

## Trois étapes, une décision éclairée

| Analyser | Vérifier | Confirmer |
| --- | --- | --- |
| Sélectionne une application. Clair recherche ses fichiers dans les dossiers habituels de macOS. | Examine les chemins, tailles estimées et raisons de chaque correspondance. Ouvre les fichiers dans le Finder. | Choisis la Corbeille ou la suppression définitive. Chaque application exige sa propre confirmation. |

## Fonctionnalités

- **Analyse locale** des préférences, caches, journaux, conteneurs, données WebKit et autres emplacements usuels.
- **Sélection prudente** : les correspondances incertaines restent décochées ; les groupes partagés et composants système sont protégés.
- **Confirmation explicite** : liste des chemins avant toute action ; saisie du nom pour une suppression définitive.
- **Corbeille par défaut**, jamais vidée automatiquement.
- **Rapport exportable** et journal des réussites et échecs de la session.
- **Analyse partielle signalée** si des dossiers ne peuvent pas être lus.
- Interface française, sans compte et sans requête réseau de l’application.

## Installation

1. Ouvre la [dernière release](https://github.com/sergefavy/clair/releases/latest).
2. Télécharge **Clair-1.0.0-arm64.dmg**, ouvre-le et glisse **Clair.app** dans **Applications**.
3. Lance Clair, choisis une application et clique sur **Analyser**.

La version fournie cible **Apple Silicon**. macOS 14 est le minimum déclaré ; les vérifications interactives ont été réalisées sur macOS 27.0.1. La signature est locale **ad hoc**, sans certificat Developer ID ni notarisation Apple : macOS peut bloquer le premier lancement. Aucune mise à jour automatique n’est incluse. Le ZIP constitue une alternative au DMG.

Les empreintes SHA-256 sont fournies avec chaque release pour contrôler l’intégrité des fichiers téléchargés.

## Avant de nettoyer

Les fichiers sélectionnés peuvent contenir des données personnelles et des sessions : vérifie-les et sauvegarde ce que tu veux conserver. Quitte l’application ciblée avant de confirmer.

Clair ne garantit pas « zéro résidu ». Les fichiers portant un autre nom peuvent échapper à l’analyse. Les trousseaux, reçus d’installation, documents, données cloud, groupes partagés et composants système ne sont pas supprimés. Pour les VPN, pilotes ou services privilégiés, utilise le désinstalleur de l’éditeur.

Le périmètre exact, les protections et les limites sont décrits dans le [guide](docs/GUIDE.md). Les [vérifications réalisées](VALIDATION.md) distinguent les tests sur fichiers fictifs des essais sur de vraies applications.

## Développement

Swift 6, SwiftUI et AppKit ; aucune dépendance tierce.

```sh
git clone https://github.com/sergefavy/clair.git
cd clair
swift run ClairChecks
zsh scripts/build.sh
open build/Clair.app
zsh scripts/make-release.sh
```

- `Sources/Core` : détection, validation des chemins et traitement des fichiers.
- `Sources/App` : interface et confirmation utilisateur.
- `Tests` : 12 contrôles sur des fichiers fictifs créés dans le dossier de travail.
- `scripts` : compilation et création du DMG, du ZIP et des sommes SHA-256.

Les tests ne désinstallent aucun logiciel existant. La publication automatique d’une release se fait en poussant un tag `vX.Y.Z` correspondant à la version d’`Info.plist` : le workflow vérifie le code, compile l’application et joint les fichiers de distribution.

## English

Clair is a native macOS application for reviewing app-related files before cleanup. It shows paths, estimated sizes and match confidence. Moving to Trash is the default; permanent deletion requires typing the application's name. Shared and system components are protected. Scans may be incomplete and do not guarantee removal of every leftover.

The interface is currently in French. Download the Apple Silicon DMG from [Releases](https://github.com/sergefavy/clair/releases/latest). Builds are ad hoc signed, not Apple notarized.
