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
    $actionFr = if($action -eq "Move"){"Déplacer"}else{"Supprimer"};
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