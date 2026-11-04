# Guide de Clair

## Désinstaller une application

1. Quitte l'application à désinstaller (Clair te propose de la quitter si besoin).
2. Sélectionne-la dans la liste, ou glisse son icône dans la fenêtre de Clair.
3. Vérifie la liste. La loupe affiche chaque élément dans le Finder.
4. Clique sur **Mettre à la Corbeille** (⌘⌫).

Les éléments sont classés en trois groupes :

| Groupe | Règle | Coché par défaut |
| --- | --- | --- |
| **Associés à l'application** | Identifiant exact (`com.editeur.app`), composant embarqué du même éditeur, service launchd qui lance un programme de l'app, nom identique à l'app dans ton dossier personnel, dossier « Éditeur/App » quand l'éditeur correspond à l'identifiant | Oui |
| **À vérifier** | Variante de l'identifiant, nom d'un composant interne, élément du même éditeur, groupes partagés, éléments communs à tous les utilisateurs trouvés par leur nom | Non |
| **Non supprimables** | Apps et fichiers Apple, extensions système et noyau | Impossible |

Une icône de cadenas signale un élément qui appartient au système : macOS demandera ton mot de passe administrateur.

## Comment se passe la suppression

1. Tous les éléments sont revérifiés : même chemin, aucun lien symbolique, fichier inchangé depuis l'analyse. Au moindre écart, rien n'est touché.
2. **L'application passe en premier.** Si macOS refuse (protection « Gestion des apps », fichiers appartenant à root), Clair demande au Finder de le faire. Si l'app ne peut pas être retirée, ses données restent intactes.
3. **Les éléments système** : les services sont arrêtés (`launchctl bootout`), les reçus oubliés (`pkgutil --forget`), le tout avec une seule demande de mot de passe. Ensuite, le Finder place les fichiers dans la Corbeille.
4. **Tes fichiers** vont dans la Corbeille. Si l'un d'eux résiste, il est confié au Finder.
5. Clair relance l'analyse et affiche ce qui reste.

Rien n'est supprimé définitivement : tu peux tout remettre en place depuis la Corbeille tant qu'elle n'est pas vidée. Si tu annules la demande de mot de passe, l'opération s'arrête.

## Restes d'applications supprimées

L'onglet **Restes** liste les préférences, caches, conteneurs, données et services nommés selon un identifiant (`com.editeur.app`) qui ne correspond plus à aucune application installée (y compris celles connues de macOS hors de `/Applications`) ni à aucun plugin (Audio Units, VST, panneaux de réglages…).

Rien n'est coché d'office. Les groupes dont l'éditeur a encore un logiciel installé sont rangés dans une section repliée : ils sont probablement encore utilisés.

## Limites

- Un fichier dont le nom ne rappelle ni l'identifiant ni le nom de l'application ne peut pas lui être attribué.
- Les trousseaux, documents, données iCloud et extensions système ne sont pas modifiés. Pour les VPN et les pilotes, préfère le désinstalleur de l'éditeur.
- Le journal se trouve dans `~/Library/Application Support/fr.sergefavy.clair/journal.txt`.
