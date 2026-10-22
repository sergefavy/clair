# Clair

Application macOS native en français pour examiner une application et ses fichiers associés avant de confirmer leur suppression. Fonctionne localement, sans compte ni requête réseau.

## Utilisation

Ouvrir `Clair.app`, sélectionner une application puis cliquer sur **Analyser**. Vérifier les chemins : le bouton dossier affiche chaque élément dans le Finder. Les données et sessions de l’application peuvent figurer dans la sélection. Sauvegarder ce qui doit être conservé.

**Examiner la suppression…** affiche la liste exacte et propose la Corbeille par défaut. Pour une suppression définitive, choisir cette méthode, cocher la vérification et saisir exactement le nom de l’application. Une confirmation est requise pour chaque application. Aucun traitement par lot ni vidage de la Corbeille. Annuler ne supprime rien.

Quitter l’application ciblée avant de confirmer. Le journal indique les réussites et les erreurs ; l’exporter pour le conserver après la fermeture de Clair. Le rapport d’analyse n’est pas une preuve de suppression. Une opération peut réussir partiellement ; les erreurs sont indiquées, et le paquet de l’application est conservé si un autre élément sélectionné échoue.

## Périmètre réel

- Applications dans `/Applications` et `~/Applications`, y compris quelques sous-dossiers.
- Dossiers utilisateur : Application Support, Caches, Preferences et ByHost, Containers, Saved Application State, Logs, HTTPStorages, WebKit, Cookies, LaunchAgents, Application Scripts, Autosave Information.
- Correspondances exactes d’identifiant proposées par défaut ; noms et composants dérivés à vérifier, décochés par défaut.
- Group Containers repérés par nom/identifiant mais toujours protégés. Les groupes aux identifiants différents ne sont pas découverts automatiquement.
- Composants correspondants du premier niveau de plusieurs dossiers `/Library` signalés sans possibilité de suppression. Utiliser le désinstalleur de l’éditeur pour les services privilégiés, VPN, pilotes et extensions système.
- Aucun accès administrateur, aucun nettoyage global, aucune modification du shell ou de son PATH.

L’analyse est ciblée : au plus trois niveaux dans les catégories qui permettent une recherche imbriquée et 25 000 entrées par catégorie. Elle ne parcourt pas les autres conteneurs d’applications. Les liens symboliques ne sont pas suivis pour la suppression. Les dossiers protégés par macOS peuvent être inaccessibles ; le rapport indique les accès refusés. Clair ne demande pas automatiquement un accès complet au disque.

**Pas de garantie « zéro résidu ».** Les fichiers sans correspondance de nom, les trousseaux, reçus d’installation, documents, sauvegardes, données cloud et composants protégés restent en place. La taille affichée est logique, parfois partielle ; elle ne représente pas nécessairement l’espace réellement récupérable sur APFS. Les agents déjà actifs ne sont pas arrêtés automatiquement et peuvent recréer des fichiers jusqu’à la fermeture de session. Une correspondance de nom ne constitue pas une preuve d’appartenance exclusive.

## Protections

Applications Apple et Clair protégées. Racines de dossiers et groupes partagés interdits. Vérification du chemin résolu, du périmètre autorisé, de l’identité et de la date de modification de chaque élément avant traitement. Ces vérifications ne constituent pas une garantie contre une modification concurrente malveillante du système de fichiers ; fermer les applications concernées avant toute opération.

## Compilation et tests

macOS 14 minimum ; compilation avec les outils de ligne de commande Xcode et Swift 6 :

```sh
cd /chemin/vers/Clair
swift run ClairChecks
zsh scripts/build.sh
open build/Clair.app
```

La version fournie est compilée pour Apple Silicon et signée localement (ad hoc), sans notarisation Apple. Les sources sont incluses. Aucun logiciel tiers n’a été désinstallé pour la vérifier.
