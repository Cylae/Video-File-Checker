# Video File Integrity Checker

An advanced PowerShell script to check the integrity of video files, find duplicates, and manage corrupted files.

## Description

This script recursively analyzes a folder of your choice to find potentially corrupt video files using **FFmpeg**. It is designed to be both powerful and user-friendly, with an interactive console UI, fully customizable configuration, and multi-language support.

## Features

-   **Corruption Analysis:** Uses FFmpeg to detect errors in video files.
-   **Parallel Processing:** Analyzes multiple files simultaneously for maximum speed, adapting to your processor's core count.
-   **Duplicate Detection:** (Also parallelized) Scans files to find exact duplicates based on their SHA256 hash.
-   **Corrupted File Management:** Offers to **delete** or **move** corrupted files to a quarantine folder.
-   **Responsive UI:** The console display adapts to the window size.
-   **External Configuration:** All settings are managed via an easy-to-edit `config.json` file.
-   **Multi-language Support:** The UI is available in English and French (configurable via `config.json`).
-   **Assisted Installation:** The script can automatically download and install FFmpeg if it's not detected.
-   **Easy Cancellation:** Press `q` or `Ctrl+C` at any time to stop the script gracefully.

## Prerequisites

-   **Windows**
-   **PowerShell 4.0 or higher**. The script will check your version on startup.
-   **FFmpeg**. If you don't have it, the script will offer to install it for you.

## Installation

1.  Download all project files (especially `Script.ps1`).
2.  Place them in a folder of your choice.
3.  If you don't have FFmpeg, the script will handle it for you on the first run.

## Usage

1.  Right-click on `Script.ps1` and choose "Run with PowerShell".
2.  A window will open asking you to select the folder to analyze.
3.  The analysis will begin. Follow the on-screen instructions.

## Configuration (`config.json`)

The script is fully configurable via the `config.json` file. If it doesn't exist, a default file will be created on the first run.

Here is a detailed description of each setting:

| Section               | Setting               | Description                                                                                                                                                             |
| --------------------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **FFmpegSettings**    | `DownloadUrl`         | The URL to download the FFmpeg 7z archive.                                                                                                                            |
|                       | `CustomCommand`       | The FFmpeg command to execute. `{filePath}` will be replaced with the file path. **Warning:** Modify with caution, as this uses `Invoke-Expression`.                     |
|                       | `Examples_...`        | Example commands for GPU acceleration (NVIDIA, AMD, Intel) to copy into `CustomCommand`.                                                                                 |
| **SevenZipUrl**       |                       | The URL to download a portable version of 7-Zip, required for the automatic FFmpeg installation.                                                                       |
| **Performance**       | `MaxConcurrentJobs`   | The maximum number of files to analyze in parallel. Set to `0` for automatic detection (number of cores - 1).                                                          |
| **Analysis**          | `MaxFilesToAnalyze`   | Allows limiting the analysis to the first N files found. Set to `0` to analyze all files. Very useful for testing.                                                     |
| **Language**          |                       | The UI language. Possible values: `"en"` (English), `"fr"` (French).                                                                                                     |
| **CorruptedFileAction** | `Action`              | The action to perform on corrupted files. Possible values: `"Delete"` or `"Move"`.                                                                                      |
|                       | `MovePath`            | The destination folder for moved files if the action is "Move".                                                                                                         |
| **DuplicateFileCheck**| `Enabled`             | Enable (`true`) or disable (`false`) the duplicate file check. **Warning:** Can be very time-consuming.                                                                 |
| **VideoExtensions**   |                       | The list of video file extensions to analyze.                                                                                                                           |
| **UI**                | `ShowBanner`          | Show (`true`) or hide (`false`) the info banner on script startup.                                                                                                     |

## Localization

Adding new languages is easy:
1.  Copy `en.json` to a new file (e.g., `es.json` for Spanish).
2.  Translate the string values in the new file.
3.  Change the `Language` setting in `config.json` to `"es"`.

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
