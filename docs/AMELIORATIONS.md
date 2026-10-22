# Prochaine mise à jour — 22 octobre 2026

Source : discussion partagée par l’utilisateur, « Corriger désinstallation Clair ».

## Réalisé

- Sélection figée pendant la confirmation, protection contre un second traitement concurrent.
- Contrôle du résultat de Corbeille, conservation du chemin de destination, contrôle de disparition du chemin initial.
- Nouvelle analyse après traitement ; fichiers conservés et restrictions visibles, aucune déclaration de nettoyage total.
- Identification générique par métadonnées du paquet, composants embarqués et exécutable des agents de démarrage. Aucune règle spécifique à Webex/OBS. Inspection de certains dossiers globaux sans droit de suppression.
- Contrôle du périmètre par chemin, sans exception propre à Final Cut Pro.
- Surface de clic étendue aux lignes d’applications et aux noms de fichiers ; boutons Finder agrandis.
- Journal local persistant et exportable.

## Validation et suite

17 contrôles automatisés, dont des suppressions uniquement sur fichiers fictifs. La désinstallation réelle et la Corbeille réelle n’ont pas été testées. Ne pas présenter cette préparation comme une validation exhaustive.

Restent : vérification des signatures, reçus, état des services/extensions, restauration automatique, progression détaillée des scans et essais sur plusieurs versions de macOS. La recherche par nom des applications déjà supprimées est reportée conformément à la discussion.

La version stable publique 1.0.0 reste distincte de cette préparation. Aucune publication ni automatisation pour le 29 octobre n’a été déclenchée.

Le bouton Arrêter rend la main et invalide le résultat de l’analyse annulée. Une lecture système déjà engagée peut terminer ultérieurement ; son résultat est ignoré.

## Rectification du périmètre

Webex et OBS sont des exemples de désinstallation manuelle réussie, pas une liste de produits à prendre en charge. Le but est d’automatiser la démarche : établir l’identité, rechercher et expliquer les associations, faire confirmer un plan précis, traiter les éléments, contrôler les restes et expliquer les blocages.

Le moteur découvre maintenant les métadonnées réelles sans noms de marque codés en dur. Les identifiants et noms découverts sont conservés pendant l’opération pour que la vérification reste possible après disparition du paquet. Les tests emploient une application fictive, un ancien nom interne, une extension et un agent au nom sans rapport.

Limite : un ancien nom absent du paquet, des données portant un nom arbitraire ou un composant installé ailleurs sans lien explicite ne peuvent pas être attribués avec ces seuls indices. L’équivalence complète avec une investigation manuelle au terminal n’est pas encore atteinte.

Référence technique : [clés Info.plist Apple](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html).
