# Vérifications de Clair 1.0

Vérifié le 22 octobre 2026 sur le Mac Apple Silicon de cette session, macOS 27.0.1.

- Compilation native Swift en mode release réussie.
- Signature locale ad hoc vérifiée avec `codesign --verify --deep --strict`.
- 12 contrôles automatisés réussis : limites d’identifiants, préférences UUID, dossiers protégés, liens symboliques directs et parents, lecture sans suppression, sélection prudente, modification depuis l’analyse, protection Apple, limites de chemins, suppression définitive de fichiers fictifs, annulation avant traitement si un élément a changé, mesure sans suivre les liens.
- Application lancée et interface inspectée visuellement.
- Analyse réelle en lecture seule d’AppCleaner : cinq éléments identifiés. Plusieurs dossiers inaccessibles, donc analyse partielle ; aucune affirmation d’exhaustivité.
- Dialogue de confirmation inspecté dans les deux modes. Suppression définitive désactivée sans saisie du nom. Annulation vérifiée.
- AppCleaner et ses fichiers repérés sont restés en place. Aucun logiciel de l’utilisateur n’a été désinstallé.

## Limites de validation

La suppression définitive a été exécutée uniquement sur des fichiers fictifs créés par les tests. Le déplacement réel vers la Corbeille et la désinstallation complète d’un logiciel utilisateur n’ont pas été exécutés. Les autres versions de macOS et les Mac Intel ne sont pas testés. Application non notarisée, distribution locale.

Les protections réduisent les erreurs de ciblage ; elles ne garantissent ni la découverte de tous les résidus ni l’absence de modification concurrente par un autre processus. Voir docs/GUIDE.md pour le périmètre exact.
