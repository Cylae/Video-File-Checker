# Set console encoding to UTF-8 for special characters (emojis)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8


# --- Script Information ---
$ScriptVersion = "2.0.0"

# --- Global Variables ---
$corruptedFiles = [System.Collections.Generic.List[object]]::new()
$duplicateFileGroups = @{}
$fileHashes = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
$logBuffer = [System.Collections.Generic.List[string]]::new()
$config = $null
$lang = @{}

# --- Functions ---

function Initialize-Script {
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
    if (-not (Test-Path $configPath)) {
        Write-Host "Configuration file not found. Creating default 'config.json'..." -ForegroundColor Yellow
        $defaultConfig = @{
            language = "en"
            performance = @{ maxConcurrentJobs = 4; enableDuplicateDetection = $false }
            ffmpeg = @{ downloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z"; command = "ffmpeg -v error -i `"{filePath}`" -f null -" }
            sevenZip = @{ downloadUrl = "https://www.7-zip.org/a/7z2301-extra.zip" }
            fileHandler = @{ videoExtensions = @(".mkv", ".mp4", ".avi", ".mov"); actionOnCorruption = "Move"; quarantinePath = "./Corrupted_Videos" }
            hashing = @{ algorithm = "SHA256" }
        }
        $defaultConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
    }
    try { $script:config = (Get-Content -Path $configPath -Raw | ConvertFrom-Json) } catch { Write-Host "FATAL: Error parsing 'config.json'." -ForegroundColor Red; exit }

    $languages = @{
        en = @{
            cancel_q = "Press 'q' to cancel"; analysis_progress = "Progress";
            ffmpeg_not_found = "FFmpeg not found."; install_ffmpeg = "Do you want the script to install FFmpeg for you? (Y/N)";
            select_folder = "Select folder to analyze."; selection_cancelled = "Selection cancelled.";
            path_not_exist = "Error: Path does not exist."; no_video_files = "No video files found.";
            analyzing = "Analyzing"; files = "files";
            analysis_complete = "Analysis complete."; duplicates_found = "Duplicate Files Found";
            corrupted_found = "Corrupted Files Found"; hash = "Hash";
            confirm_action = "Do you want to {0} all {1} corrupted files? (Y/N)";
            action_cancelled = "{0} cancelled. No files were {1}.";
            summary_title = "--- {0} Summary ---"; status = "Status"; path = "Path";
            action_success = "SUCCESS: '{0}' was {1}."; action_failed = "ERROR: Failed to {2} '{0}': {1}";
            report_saved = "CSV report saved to"; script_finished = "Script finished. Log saved to"
        }
        fr = @{
            cancel_q = "Appuyez sur 'q' pour annuler"; analysis_progress = "Progression";
            ffmpeg_not_found = "FFmpeg non trouvé."; install_ffmpeg = "Voulez-vous que le script installe FFmpeg pour vous? (O/N)";
            select_folder = "Sélectionnez le dossier à analyser."; selection_cancelled = "Sélection annulée.";
            path_not_exist = "Erreur : Le chemin n'existe pas."; no_video_files = "Aucun fichier vidéo trouvé.";
            analyzing = "Analyse de"; files = "fichiers";
            analysis_complete = "Analyse terminée."; duplicates_found = "Fichiers Dupliqués Trouvés";
            corrupted_found = "Fichiers Corrompus Trouvés"; hash = "Hash";
            confirm_action = "Voulez-vous {0} les {1} fichiers corrompus? (O/N)";
            action_cancelled = "Opération {0} annulée. Aucun fichier n'a été {1}.";
            summary_title = "--- Résumé de l'{0} ---"; status = "Statut"; path = "Chemin";
            action_success = "SUCCÈS : '{0}' a été {1}."; action_failed = "ERREUR : Échec de {2} '{0}': {1}";
            report_saved = "Rapport CSV enregistré dans"; script_finished = "Script terminé. Log enregistré dans"
        }
    }
    $script:lang = $languages[$config.language]
}

function Show-Banner { $date = Get-Date -Format "yyyy-MM-dd"; Write-Host "--- Cylae Video File Checker v$($ScriptVersion) ---" -ForegroundColor Green; Write-Host "Date: $date | Link: https://cyl.ae/"; Write-Host "-------------------------------------------------`n" }
function Write-Log { param([string]$Message) $logBuffer.Add("[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message") }
function Write-AllLogs { Set-Content -Path (Join-Path $PSScriptRoot "script_log.txt") -Value ($logBuffer -join "`n") -Encoding UTF8 }
function Test-FFmpeg { Write-Host "Checking for FFmpeg..."; try { Get-Command ffmpeg.exe -EA Stop | Out-Null; Write-Host "FFmpeg is installed." -FG Green; return $true } catch { Write-Host $lang.ffmpeg_not_found -FG Yellow; return $false } }
function Install-FFmpeg {
    # This function is a placeholder. A full implementation would require downloading
    # and extracting FFmpeg and 7-Zip, which is a complex task. For now, please
    # install FFmpeg manually and ensure it is in your system's PATH.
    return $false
}
function Test-UserConfirmation { param([string]$Prompt) while ($true) { $c = Read-Host $Prompt; if ($c -match '^(y|o|yes|oui)$') { return $true }; if ($c -match '^(n|no|non)$') { return $false } } }
function Select-Folder { Add-Type -A System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = $lang.select_folder; if ($d.ShowDialog() -eq 'OK') { return $d.SelectedPath }; return $null }
function Truncate-Path { param([string]$Path, [int]$MaxLength) if ($Path.Length -gt $MaxLength) { $s = [int]($MaxLength/2)-2; $e = $MaxLength-$s-3; return "$($Path.Substring(0,$s))...$($Path.Substring($Path.Length-$e))" }; return $Path }

function Write-ProgressBar {
    param([double]$Percentage, [int]$Line)
    $width = $Host.UI.RawUI.WindowSize.Width
    if ($width -lt 20) { $width = 20 }
    $percentText = " $($Percentage.ToString('F2'))% "
    $barWidth = $width - $percentText.Length - 2
    if ($barWidth -lt 1) { $barWidth = 1 }
    $filledWidth = [int]($barWidth * ($Percentage / 100))
    $bar = ('█' * $filledWidth) + ('▒' * ($barWidth - $filledWidth))
    [System.Console]::SetCursorPosition(0, $Line); [System.Console]::Write(' ' * $width); [System.Console]::SetCursorPosition(0, $Line); [System.Console]::Write("$percentText|$bar|")
}

# --- Main ---
Initialize-Script
trap { Write-Host "`nStopping..." -FG Red; $jobs|Stop-Job -EA SilentlyContinue; $jobs|Wait-Job|Out-Null; $jobs|Remove-Job; Write-AllLogs; [Console]::ResetColor(); exit }
Show-Banner

if (-not (Test-FFmpeg)) { if (-not (Install-FFmpeg)) { exit } }
$folderPath = Select-Folder
if (!$folderPath) { Write-Host $lang.selection_cancelled -FG Yellow; exit }
if (!(Test-Path $folderPath)) { Write-Log "ERROR: Path '$folderPath' DNE."; Write-Host $lang.path_not_exist -FG Red; exit }

$videoFiles = Get-ChildItem -Path $folderPath -File -Recurse | Where-Object { $config.fileHandler.videoExtensions -contains $_.Extension }
if ($videoFiles.Count -eq 0) { Write-Host $lang.no_video_files -FG Yellow; exit }

[Console]::BackgroundColor="DarkBlue"; [Console]::ForegroundColor="White"; Clear-Host
Write-Host "$($lang.analyzing) $($videoFiles.Count) $($lang.files)... ($($lang.cancel_q))"
$jobs=@(); $recent=@(New-Object System.Collections.Generic.Queue[object](10)); $completed=0; $q=New-Object System.Collections.Generic.Queue[object]($videoFiles)

while ($completed -lt $videoFiles.Count) {
    if ($Host.UI.RawUI.KeyAvailable -and ('q' -eq $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character)) { throw "User cancelled." }
    while (($jobs|? State -eq 'Running').Count -lt $config.performance.maxConcurrentJobs -and $q.Count -gt 0) {
        $file = $q.Dequeue(); $sb = {
            param($path, $cmd, $doHash, $algo)
            $cmd = $cmd.Replace("{filePath}", $path); $out = & powershell -Command $cmd 2>&1
            $hash = if($doHash){(Get-FileHash $path -Algo $algo).Hash}else{$null}
            [PSCustomObject]@{FullName=$path; IsCorrupted=(-not [string]::IsNullOrWhiteSpace($out)); FFmpegOutput=$out; Hash=$hash}
        }
        $jobs += Start-Job -ScriptBlock $sb -ArgumentList $file.FullName, $config.ffmpeg.command, $config.performance.enableDuplicateDetection, $config.hashing.algorithm
    }
    ($jobs|? State -eq 'Completed') |% {
        $completed++; $res=$_|Receive-Job -Wait -AutoRemoveJob; if($recent.Count -ge 10){$recent.Dequeue()|Out-Null}; $recent.Enqueue($res)
        if($res.IsCorrupted){$corruptedFiles.Add($res)}; if($res.Hash){$fileHashes[$res.FullName]=$res.Hash}
    }
    Write-ProgressBar -Percentage (if ($videoFiles.Count -gt 0) { ($completed / $videoFiles.Count) * 100 } else { 0 }) -Line 2
    $w=$Host.UI.RawUI.WindowSize.Width; $i=0; $recent|%{[Console]::SetCursorPosition(0,4+$i++);$s=if($_.IsCorrupted){"[X]"}else{"[V]"};Write-Host "$s $(Truncate-Path $_.FullName ($w-5))" -NoNewline;[Console]::Write(" "*($w-($Host.UI.RawUI.CursorPosition.X)))}
    Start-Sleep -ms 100
}

[Console]::ResetColor(); Clear-Host; Write-Host $lang.analysis_complete
$reports = @()

if ($config.performance.enableDuplicateDetection) {
    $duplicateGroups = $fileHashes.GetEnumerator() | Group-Object Value | Where-Object Count -gt 1
    if ($duplicateGroups) {
        Write-Host "`n--- $($lang.duplicates_found) ---" -FG Yellow
        $duplicateGroups |% { $hash = $_.Name; Write-Host "`n$($lang.hash): $hash"; $_.Group.Key |% { Write-Host " - $_"; $reports+=[PSCustomObject]@{Type="Duplicate";Status="N/A";Details=$hash;Path=$_} } }
    }
}

if ($corruptedFiles.Count -gt 0) {
    Write-Host "`n--- $($lang.corrupted_found) ---" -FG Red
    $corruptedFiles |% { Write-Host " - $($_.FullName)" }
    $action = $config.fileHandler.actionOnCorruption; $actionPast = if($action -eq "Move"){"moved"}else{"deleted"}; $actionPastFr = if($action -eq "Move"){"déplacé"}else{"supprimé"}
    $actionFr = if($action -eq "Move"){"Déplacer"}else{"Supprimer"}; $verbFr = if($action -eq "Move"){"déplace"}else{"supprime"}
    $confirmMsg = ($lang.confirm_action -f ($config.language -eq 'fr' ? $actionFr : $action), $corruptedFiles.Count)

    if (Test-UserConfirmation -Prompt $confirmMsg) {
        if ($action -eq "Move") { New-Item -Path $config.fileHandler.quarantinePath -Type Directory -EA SilentlyContinue | Out-Null }
        $corruptedFiles |% {
            $file = $_; $targetPath = Join-Path $config.fileHandler.quarantinePath ($file.FullName -split '[\\/]' | Select -Last 1)
            try {
                if ($action -eq "Move") { Move-Item -Path $file.FullName -Destination $targetPath -Force } else { Remove-Item -Path $file.FullName -Force }
                $status = $config.language -eq 'fr' ? $actionPastFr : $actionPast
                Write-Log ($lang.action_success -f $file.FullName, $status); $reports+=[PSCustomObject]@{Type="Corrupted";Status=$status;Details=$file.FFmpegOutput;Path=$file.FullName}
            } catch {
                $status = "failed to " + $action.ToLower(); $failActionFr = "Échec de " + $action.ToLower()
                Write-Log ($lang.action_failed -f $file.FullName, $_.Exception.Message, ($config.language -eq 'fr' ? $failActionFr : $status))
                $reports+=[PSCustomObject]@{Type="Corrupted";Status=$status;Details=$_.Exception.Message;Path=$file.FullName}
            }
        }
    } else {
        $actionCancelled = $config.language -eq 'fr' ? $actionFr : $action; $pastCancelled = $config.language -eq 'fr' ? $actionPastFr : $actionPast
        Write-Host ($lang.action_cancelled -f $actionCancelled, $pastCancelled) -FG Yellow
        $corruptedFiles |% { $reports+=[PSCustomObject]@{Type="Corrupted";Status="Skipped";Details=$_.FFmpegOutput;Path=$_.FullName} }
    }
}

if ($reports.Count -gt 0) {
    $reportPath = Join-Path $PSScriptRoot "report.csv"
    try {
        $reports | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
        Write-Host "`n$($lang.report_saved) $reportPath" -FG Green
    } catch {
        Write-Log "ERROR: Failed to save CSV report to '$reportPath': $($_.Exception.Message)"
        Write-Host "Error: Could not save CSV report. See log for details." -FG Red
    }
}

Write-AllLogs
Write-Host "`n$($lang.script_finished) script_log.txt"
=======
# --- Configuration ---
$config = @{
    # List of video file extensions to check (add or remove as needed)
    VideoExtensions = @('.mkv', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm');

    # Download URLs for dependencies
    FFmpegUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z";
    SevenZipUrl = "https://www.7-zip.org/a/7z2301-extra.zip";

    # --- Performance Settings ---
    # Set the maximum number of concurrent jobs.
    # By default, it leaves one core free for system stability, with a max cap of 8.
    MaxConcurrentJobs = [System.Math]::Min([int](((Get-CimInstance Win32_Processor).NumberOfLogicalProcessors) - 1), 8);
}
# Ensure at least one job runs if detection fails or on a single-core system
if ($config.MaxConcurrentJobs -lt 1) { $config.MaxConcurrentJobs = 1 }


# Define global variables for the script
$corruptedFiles = @()
$deletedFiles = @()
$logBuffer = [System.Collections.Generic.List[string]]::new()

# --- Functions ---

# Function to display the script's startup banner
function Show-Banner {
    $banner = @"
   ██████╗ ██╗   ██╗ ██╗      █████╗ ███████╗
  ██╔════╝ ██║   ██║ ██║     ██╔══██╗██╔════╝
  ██║      ██║   ██║ ██║     ███████║█████╗
  ██║      ╚██╗ ██╔╝ ██║     ██╔══██║██╔══╝
  ╚██████╗ ╚████╔╝  ███████╗██║  ██║███████╗
   ╚═════╝  ╚═══╝   ╚══════╝╚═╝  ╚═╝╚══════╝
"@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host ""
}

# Function to write logs to a file (stores in memory first)
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logBuffer.Add("[$timestamp] $Message")
}

# Function to write all logs from the buffer to the file
function Write-AllLogs {
    $logFilePath = Join-Path -Path $PSScriptRoot -ChildPath "script_log.txt"
    # Overwrite the file with the full buffer content
    Set-Content -Path $logFilePath -Value ($logBuffer -join "`n") -Encoding UTF8
}

# Function to check if FFmpeg is installed
function Test-FFmpeg {
    Write-Host "Checking for FFmpeg..."
    try {
        # Attempts to find the 'ffmpeg' command
        Get-Command ffmpeg.exe -ErrorAction Stop | Out-Null
        Write-Host "FFmpeg is installed." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "FFmpeg was not found on your system." -ForegroundColor Yellow
        return $false
    }
}

# Function to install and configure FFmpeg
function Install-FFmpeg {
    Write-Host ""
    if (Test-UserConfirmation -Prompt "Do you want the script to install FFmpeg for you? (Y/N)") {
        Write-Log "INFO: User agreed to install FFmpeg."
        Write-Host "Starting FFmpeg installation..." -ForegroundColor Cyan

        try {
            $downloadUrl = $config.FFmpegUrl
            $tempDir = Join-Path -Path $env:TEMP -ChildPath "ffmpeg_install"
            $zipFile = Join-Path -Path $tempDir -ChildPath "ffmpeg.7z"

            # --- Check and install 7-Zip if necessary ---
            $sevenZipExePath = $null
            try {
                $sevenZipExePath = (Get-Command 7z.exe -ErrorAction Stop).Path
                Write-Log "INFO: 7-Zip is already installed. Using the existing version."
            } catch {
                Write-Host "7-Zip was not found on your system." -ForegroundColor Yellow
                if (Test-UserConfirmation -Prompt "Do you want to install a portable version of 7-Zip to extract FFmpeg? (Y/N)") {
                    Write-Log "INFO: User agreed to install portable 7-Zip."
                    $sevenZipDownloadUrl = $config.SevenZipUrl
                    $sevenZipZipFile = Join-Path -Path $tempDir -ChildPath "7z.zip"

                    Write-Host "Downloading portable 7-Zip..."
                    Invoke-WebRequest -Uri $sevenZipDownloadUrl -OutFile $sevenZipZipFile -ErrorAction Stop

                    # Use PowerShell's built-in Expand-Archive for .zip files.
                    Expand-Archive -Path $sevenZipZipFile -DestinationPath $tempDir -Force

                    # Search for the 7-Zip standalone executable ('7za.exe') in the extracted files.
                    $sevenZipExePath = (Get-ChildItem -Path $tempDir -Recurse -Filter "7za.exe").FullName | Select-Object -First 1

                    if (-not ($sevenZipExePath -and (Test-Path $sevenZipExePath))) {
                        throw "The '7za.exe' executable was not found after extraction."
                    }
                } else {
                    Write-Host "Installation cancelled. The script cannot continue." -ForegroundColor Yellow
                    return $false
                }
            }

            # Create the temporary folder
            if (-not (Test-Path $tempDir)) {
                New-Item -Path $tempDir -ItemType Directory -ErrorAction Stop | Out-Null
            }

            Write-Host "Downloading FFmpeg from '$downloadUrl'..."
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -ErrorAction Stop

            Write-Host "Extracting FFmpeg archive..."
            & $sevenZipExePath x "$zipFile" "-o$tempDir" -y | Out-Null

            # Find the 'bin' folder after extraction
            $extractedDir = Get-ChildItem -Path $tempDir -Directory | Where-Object { $_.Name -like "ffmpeg*" }
            $binPath = Join-Path -Path $extractedDir.FullName -ChildPath "bin"

            if (Test-Path $binPath) {
                Write-Host "Updating the PATH environment variable..."
                # Get the current value of the user's PATH variable
                $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                # Check if the path is not already present to avoid duplicates
                if ($currentPath -notlike "*$binPath*") {
                    $newPath = "$binPath;$currentPath"
                    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                    Write-Host "Installation complete! FFmpeg is now available in the user's PATH." -ForegroundColor Green
                    Write-Host "Please restart PowerShell for the change to take effect." -ForegroundColor Yellow
                    Write-Log "SUCCESS: FFmpeg was installed and the PATH was updated."
                } else {
                    Write-Host "The FFmpeg path is already in the PATH." -ForegroundColor Yellow
                }
            } else {
                Write-Host "Error: The 'bin' folder was not found after extraction." -ForegroundColor Red
                Write-Log "ERROR: Installation failed. The 'bin' folder was not found."
                exit
            }
            return $true
        } catch {
            Write-Host "An error occurred during FFmpeg installation: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "ERROR: FFmpeg installation failed. $($_.Exception.Message)"
            return $false
        }
    } else {
        Write-Host "FFmpeg installation was cancelled. The script cannot continue." -ForegroundColor Yellow
        Write-Log "INFO: Installation cancelled. The script has ended."
        return $false
    }
}

# Function to truncate a path if it's too long
function Truncate-Path {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [int]$MaxLength
    )

    if ($Path.Length -gt $MaxLength) {
        $startLength = [int]($MaxLength / 2) - 2 # Start size, -2 for the ...
        $endLength = $MaxLength - $startLength - 3 # End size, -3 for the ... and the space

        $start = $Path.Substring(0, $startLength)
        $end = $Path.Substring($Path.Length - $endLength)

        return "$start...$end"
    }

    return $Path
}

# Function to get a confirmation from the user (Y/N)
function Test-UserConfirmation {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt
    )
    while ($true) {
        $choice = Read-Host -Prompt $Prompt
        if ($choice -match '^(y|o|yes|oui)$') {
            return $true
        }
        if ($choice -match '^(n|no|non)$') {
            return $false
        }
        Write-Host "Invalid input. Please enter 'Y' or 'N'." -ForegroundColor Yellow
    }
}

# Function to open a folder selection window
function Select-Folder {
    # Load the System.Windows.Forms assembly to use the dialog box
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select the folder to analyze."
    $dialog.ShowNewFolderButton = $true

    $result = $dialog.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    } else {
        return $null
    }
}

# --- Main Script ---

# --- Interruption handling block (Ctrl+C) and global error handler ---
trap {
    # This block runs if the user presses Ctrl+C or an error occurs
    Write-Host "`nStopping current tasks..." -ForegroundColor Red
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Wait-Job | Out-Null
    $jobs | Remove-Job
    Write-AllLogs
    # Restore default console colors
    $host.ui.rawui.backgroundcolor = "Black"
    $host.ui.rawui.foregroundcolor = "White"
    Write-Host "Tasks stopped. The script is now closing." -ForegroundColor Cyan
    exit
}
# --- End of interruption and error handling block ---

# Show the startup banner
Show-Banner

# Step 0: Check for existing FFmpeg processes
Write-Host "Checking for existing FFmpeg processes..." -ForegroundColor White
$ffmpegProcesses = Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue
if ($ffmpegProcesses) {
    Write-Host "Warning: $($ffmpegProcesses.Count) 'ffmpeg.exe' processes were found running." -ForegroundColor Yellow
    if (Test-UserConfirmation -Prompt "Do you want to stop these processes to ensure the script runs correctly? (Y/N)") {
        Write-Host "Stopping FFmpeg processes..." -ForegroundColor Cyan
        Stop-Process -Name "ffmpeg" -Force -ErrorAction SilentlyContinue
        Write-Host "Processes stopped." -ForegroundColor Green
        Write-Log "INFO: User chose to stop running FFmpeg processes."
    } else {
        Write-Host "FFmpeg processes must be manually closed for the script to continue." -ForegroundColor Red
        Write-Host "Please close the processes and restart the script."
        Write-Log "INFO: User chose not to stop processes. Exiting script."
        Read-Host -Prompt "Press any key to exit..."
        exit
    }
} else {
    Write-Host "No running FFmpeg processes were found." -ForegroundColor Green
}
Write-Host ""


# Step 1: Check and install FFmpeg if necessary
if (-not (Test-FFmpeg)) {
    if (-not (Install-FFmpeg)) {
        exit
    }
}
Write-Host ""

# Step 2: Ask the user for the path via a selection window
Write-Host "A folder selection window will open. Please choose the folder to analyze."
$folderPath = Select-Folder
Write-Host "Selected folder: $folderPath"

# Check if a path was selected
if ([string]::IsNullOrEmpty($folderPath)) {
    Write-Host "Selection cancelled. The script will stop." -ForegroundColor Yellow
    Write-Log "INFO: User cancelled the selection. The script has ended."
    exit
}

# Check if the path exists (less likely with the dialog box)
if (-not (Test-Path -Path $folderPath)) {
    Write-Host "Error: The path '$folderPath' does not exist." -ForegroundColor Red
    Write-Log "ERROR: The path '$folderPath' does not exist."
    exit
}

# Step 3: Get the list of video files
$videoFiles = Get-ChildItem -Path $folderPath -File -Recurse | Where-Object {
    $_.Extension -in $config.VideoExtensions
}

Write-Log "INFO: $($videoFiles.Count) video files were detected for analysis."

if ($videoFiles.Count -eq 0) {
    Write-Host "No video files found in the folder and its subfolders." -ForegroundColor Yellow
    Write-Log "INFO: No video files found. The script has ended."
    exit
}

# Step 4: Parallel analysis with dynamic CPU usage control and enhanced UI
Clear-Host # Clear the window for a clean start
Write-Host "Analysis in progress... (Press Ctrl+C to cancel)"
Write-Log "INFO: Starting parallel analysis via jobs."

# Set console colors for a better visual experience
$host.ui.rawui.backgroundcolor = "DarkBlue"
$host.ui.rawui.foregroundcolor = "White"
Clear-Host

# Get the maximum number of concurrent jobs from the config
$maxConcurrentJobs = $config.MaxConcurrentJobs

# Array to store ongoing jobs and recently completed files
$jobs = @()
$recentlyAnalyzedFiles = [System.Collections.Generic.Queue[object]]::new(10)
$jobsCompleted = 0
$filesToAnalyze = [System.Collections.Generic.Queue[object]]$videoFiles
$totalFiles = $videoFiles.Count
$consoleWidth = $Host.UI.RawUI.WindowSize.Width
$progressLine = 2
$headerLine = 0
$listStartLine = 4
$listCount = 10
$spinner = @('|', '/', '-', '\')
$spinnerIndex = 0

# Initial UI setup
Write-Host "Analyzing $totalFiles video files... (Press Ctrl+C to cancel)"
Write-Host ""
Write-Host "------------------------------------------------"
Write-Host "Recently analyzed files:"

# Main loop
while ($jobsCompleted -lt $totalFiles) {
    # Start new jobs if the number of running jobs is less than the maximum
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -lt $maxConcurrentJobs -and $filesToAnalyze.Count -gt 0) {
        $file = $filesToAnalyze.Dequeue()
        $jobs += Start-Job -ScriptBlock {
            param($filePath)

            # Start the check with FFmpeg
            $result = & "ffmpeg" -v error -i "$filePath" -f null - 2>&1
            $isCorrupted = (-not [string]::IsNullOrWhiteSpace($result))

            # Return the results
            [PSCustomObject]@{
                FullName = $filePath
                IsCorrupted = $isCorrupted
                FFmpegOutput = $result
            }
        } -ArgumentList $file.FullName
    }

    # Check for completed jobs
    $completedJobs = $jobs | Where-Object { $_.State -eq 'Completed' }

    if ($completedJobs) {
        foreach ($job in $completedJobs) {
            $jobsCompleted++

            $null = $result = $job | Receive-Job -Keep

            # Add result to the recent files queue, keeping the size capped
            if ($recentlyAnalyzedFiles.Count -ge $listCount) {
                $recentlyAnalyzedFiles.Dequeue()
            }
            $recentlyAnalyzedFiles.Enqueue($result)

            # Write to log
            if ($result.IsCorrupted) {
                $corruptedFiles += $result.FullName
                Write-Log "CORRUPTED: The file '$($result.FullName)' appears to be corrupted. Error: $($result.FFmpegOutput)"
            }
            else {
                Write-Log "OK: The file '$($result.FullName)' is valid."
            }
        }

        # Remove the completed jobs from the main list and clean them up from memory
        $jobs = $jobs | Where-Object { $_.State -ne 'Completed' }
        $completedJobs | Remove-Job
    }

    # --- UI Refresh Section without flickering ---
    # Update progress bar
    $progressPercentage = ($jobsCompleted / $totalFiles) * 100
    $progressText = "Progress: $([math]::Round($progressPercentage, 2))% - $jobsCompleted of $totalFiles files analyzed "

    # Update spinner
    $spinnerIndex = ($spinnerIndex + 1) % $spinner.Count
    $spinnerChar = $spinner[$spinnerIndex]

    [System.Console]::SetCursorPosition(0, $progressLine)
    [System.Console]::Write($progressText + $spinnerChar + (" " * ($consoleWidth - $progressText.Length - 1)))

    # Update the list of recently analyzed files
    $i = 0
    $recentlyAnalyzedFiles | ForEach-Object {
        $statusText = if ($_.IsCorrupted) { "[Corrupted]" } else { "[Not corrupted]" }
        $foregroundColor = if ($_.IsCorrupted) { "Red" } else { "Green" }

        $truncatedPath = Truncate-Path -Path $_.FullName -MaxLength ($consoleWidth - ($statusText.Length + 2))
        $output = "$statusText $truncatedPath"

        [System.Console]::SetCursorPosition(0, $listStartLine + $i)
        $host.ui.rawui.foregroundcolor = $foregroundColor
        [System.Console]::Write($output + (" " * ($consoleWidth - $output.Length)))
        $i++
    }
    # Restore default color for other text
    $host.ui.rawui.foregroundcolor = "White"
    # --- End UI Refresh Section ---

    # Short pause to avoid overwhelming the processor
    Start-Sleep -Milliseconds 100
}

# Clean up jobs after execution
Remove-Job -Job $jobs

# Write all logs from buffer to file
Write-AllLogs

# Restore default console colors
$host.ui.rawui.backgroundcolor = "Black"
$host.ui.rawui.foregroundcolor = "White"
Clear-Host

# Step 5: Final summary and interactive deletion actions
Write-Host ""
Write-Host "--- Analysis Summary ---"
Write-Host "Video files analyzed: $($totalFiles)"
Write-Host "Corrupted files detected: $($corruptedFiles.Count)"

# Interactive deletion
if ($corruptedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "List of corrupted files found: " -ForegroundColor Red
    $corruptedFiles | ForEach-Object { Write-Host " - $_" }

    Write-Host ""
    Write-Host "WARNING: The action below is irreversible." -ForegroundColor Yellow

    $fileActions = @{}
    if (Test-UserConfirmation -Prompt "Do you want to PERMANENTLY DELETE all $($corruptedFiles.Count) listed files? (Y/N)") {
        foreach ($file in $corruptedFiles) {
            try {
                Write-Host "Deleting '$file'..." -ForegroundColor Cyan
                Remove-Item -Path $file -Recurse -Force -ErrorAction Stop
                $deletedFiles += $file
                $fileActions[$file] = "[Deleted]"
                Write-Log "SUCCESS: '$file' was permanently deleted."
            } catch {
                $fileActions[$file] = "[Failed to delete]"
                Write-Host "Error deleting '$file': $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "ERROR: Failed to delete '$file': $($_.Exception.Message)"
            }
        }
        Write-Log "INFO: User chose to delete files. Summary: $($deletedFiles.Count) of $($corruptedFiles.Count) corrupted files were deleted."
    } else {
        Write-Host "Deletion cancelled. No files were deleted." -ForegroundColor Cyan
        Write-Log "INFO: User chose not to delete any files."
        # Populate actions for the report
        foreach ($file in $corruptedFiles) {
            $fileActions[$file] = "[Not Deleted]"
        }
    }

    # Final summary with table
    Write-Host ""
    Write-Host "--- Deletion Summary ---"
    Write-Host ""

    $table = $corruptedFiles | ForEach-Object {
        [PSCustomObject]@{
            Status = $fileActions[$_]
            Path = $_
        }
    }

    $table | Format-Table -AutoSize
} else {
    Write-Host "No corrupted files were found." -ForegroundColor Green
    Write-Log "INFO: No corrupted files were found."
}

Write-Host ""
Write-Host "Script finished." -ForegroundColor Cyan
main
