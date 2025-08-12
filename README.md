# Video File Integrity Checker

Un script PowerShell avancé pour vérifier l'intégrité des fichiers vidéo, trouver les doublons, et gérer les fichiers corrompus.

## Description

Ce script analyse de manière récursive un dossier de votre choix pour trouver des fichiers vidéo potentiellement corrompus en utilisant **FFmpeg**. Il est conçu pour être à la fois puissant et facile à utiliser, avec une interface utilisateur interactive dans la console, une configuration entièrement personnalisable, et un support multilingue.

## Fonctionnalités

-   **Analyse de corruption :** Utilise FFmpeg pour détecter les erreurs dans les fichiers vidéo.
-   **Traitement parallèle :** Analyse plusieurs fichiers simultanément pour une vitesse maximale, en s'adaptant au nombre de cœurs de votre processeur.
-   **Détection des doublons :** Analyse (en parallèle) les fichiers pour trouver les doublons exacts en se basant sur leur hash SHA256.
-   **Gestion des fichiers corrompus :** Propose de **supprimer** ou de **déplacer** les fichiers corrompus vers un dossier de quarantaine.
-   **Interface réactive :** L'affichage dans la console s'adapte à la taille de la fenêtre.
-   **Configuration externe :** Tous les paramètres sont gérés via un fichier `config.json` facile à modifier.
-   **Support multilingue :** L'interface est disponible en Français et en Anglais (configurable via `config.json`).
-   **Installation assistée :** Le script peut télécharger et installer automatiquement FFmpeg s'il n'est pas détecté.
-   **Annulation facile :** Appuyez sur `q` ou `Ctrl+C` à tout moment pour arrêter le script proprement.

## Prérequis

-   **Windows**
-   **PowerShell 4.0 ou supérieur**. Le script vérifiera votre version au démarrage.
-   **FFmpeg**. Si vous ne l'avez pas, le script vous proposera de l'installer pour vous.

## Installation

1.  Téléchargez tous les fichiers du projet (notamment `Script.ps1`).
2.  Placez-les dans un dossier de votre choix.
3.  Si vous n'avez pas FFmpeg, le script s'en occupera pour vous au premier lancement.

## Utilisation

1.  Faites un clic droit sur `Script.ps1` et choisissez "Exécuter avec PowerShell".
2.  Une fenêtre s'ouvrira pour vous demander de sélectionner le dossier à analyser.
3.  L'analyse commencera. Suivez les instructions à l'écran.

## Configuration (`config.json`)

Le script est entièrement configurable via le fichier `config.json`. S'il n'existe pas, un fichier par défaut sera créé au premier lancement.

Voici une description détaillée de chaque paramètre :

| Section               | Paramètre             | Description                                                                                                                                                             |
| --------------------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **FFmpegSettings**    | `DownloadUrl`         | L'URL pour télécharger l'archive 7z de FFmpeg.                                                                                                                          |
|                       | `CustomCommand`       | La commande FFmpeg à exécuter. `{filePath}` sera remplacé par le chemin du fichier. **Attention :** Modifiez avec prudence, car cela utilise `Invoke-Expression`.             |
|                       | `Examples_...`        | Des exemples de commandes pour l'accélération GPU (NVIDIA, AMD, Intel) à copier dans `CustomCommand`.                                                                    |
| **SevenZipUrl**       |                       | L'URL pour télécharger une version portable de 7-Zip, nécessaire pour l'installation automatique de FFmpeg.                                                              |
| **Performance**       | `MaxConcurrentJobs`   | Le nombre maximum de fichiers à analyser en parallèle. Mettez `0` pour une détection automatique (nombre de cœurs - 1).                                                   |
| **Analysis**          | `MaxFilesToAnalyze`   | Permet de limiter l'analyse aux N premiers fichiers trouvés. Mettez `0` pour analyser tous les fichiers. Très utile pour les tests.                                      |
| **Language**          |                       | La langue de l'interface. Valeurs possibles : `"en"` (Anglais), `"fr"` (Français).                                                                                       |
| **CorruptedFileAction** | `Action`              | L'action à effectuer sur les fichiers corrompus. Valeurs possibles : `"Delete"` (Supprimer) ou `"Move"` (Déplacer).                                                        |
|                       | `MovePath`            | Le dossier de destination pour les fichiers déplacés si l'action est "Move".                                                                                            |
| **DuplicateFileCheck**| `Enabled`             | Activer (`true`) ou désactiver (`false`) la recherche de fichiers en double. **Attention :** peut être très long.                                                         |
| **VideoExtensions**   |                       | La liste des extensions de fichiers vidéo à analyser.                                                                                                                   |
| **UI**                | `ShowBanner`          | Afficher (`true`) ou cacher (`false`) la bannière d'information au démarrage du script.                                                                                |

## Localisation

L'ajout de nouvelles langues est facile :
1.  Copiez `en.json` vers un nouveau fichier (par exemple `es.json` pour l'espagnol).
2.  Traduisez les valeurs des chaînes de caractères dans le nouveau fichier.
3.  Changez le paramètre `Language` dans `config.json` en `"es"`.

## Licence

Ce projet est sous licence MIT. Voir le fichier `LICENSE` pour plus de détails.
