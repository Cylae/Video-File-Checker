# --- Pre-flight Checks ---
if ($PSVersionTable.PSVersion.Major -lt 4) {
    Write-Error "PowerShell 4.0 or higher is required to run this script (for the Get-FileHash cmdlet). Your current version is $($PSVersionTable.PSVersion). Please upgrade and try again."
    if ($Host.Name -eq "ConsoleHost") { Read-Host "Press Enter to exit" }
    exit
}

# Set console encoding to UTF-8 for special characters (emojis)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Configuration ---
# Function to load settings from config.json
function Load-Config {
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

            # --- Config Migration/Defaults ---
            # This ensures that if the script is updated but the user has an old config file,
            # the script will not fail and will use default values for new settings.
            if (-not $config.PSObject.Properties.Name.Contains('Performance')) {
                $config | Add-Member -MemberType NoteProperty -Name 'Performance' -Value @{ MaxConcurrentJobs = 0 }
            }
            if (-not $config.Performance.PSObject.Properties.Name.Contains('MaxConcurrentJobs')) {
                $config.Performance | Add-Member -MemberType NoteProperty -Name 'MaxConcurrentJobs' -Value 0
            }
            if (-not $config.PSObject.Properties.Name.Contains('UI')) {
                $config | Add-Member -MemberType NoteProperty -Name 'UI' -Value @{ ShowBanner = $true }
            }
            if (-not $config.UI.PSObject.Properties.Name.Contains('ShowBanner')) {
                $config.UI | Add-Member -MemberType NoteProperty -Name 'ShowBanner' -Value $true
            }
            # --- End Config Migration ---

            # Handle auto-detection of MaxConcurrentJobs
            if ($config.Performance.MaxConcurrentJobs -le 0) {
                # Auto-set: leaves one core free, with a max cap of 8.
                $detectedJobs = [System.Math]::Min([int](((Get-CimInstance Win32_Processor).NumberOfLogicalProcessors) - 1), 8)
                $config.Performance.MaxConcurrentJobs = if ($detectedJobs -lt 1) { 1 } else { $detectedJobs }
            }
            return $config
        } catch {
            Write-Host "Error reading or parsing config.json. $($_.Exception.Message)" -ForegroundColor Red
            # Fallback to default settings if config is corrupted
            return Get-DefaultConfig
        }
    } else {
        # If the file doesn't exist, create it with default values
        Write-Host "config.json not found. Creating a default configuration file." -ForegroundColor Yellow
        $defaultConfig = Get-DefaultConfig
        # Auto-set MaxConcurrentJobs for the default config as well
        $detectedJobs = [System.Math]::Min([int](((Get-CimInstance Win32_Processor).NumberOfLogicalProcessors) - 1), 8)
        $defaultConfig.Performance.MaxConcurrentJobs = if ($detectedJobs -lt 1) { 1 } else { $detectedJobs }

        $defaultConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
        return $defaultConfig
    }
}

# Function to get the default configuration settings
function Get-DefaultConfig {
    return [PSCustomObject]@{
        FFmpegSettings = @{
            DownloadUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z'
            # WARNING: The CustomCommand is executed via Invoke-Expression, which can be a security risk.
            # Only use commands from trusted sources. Ensure the command correctly handles file paths with spaces,
            # for example by enclosing "{filePath}" in quotes within the command string.
            CustomCommand = 'ffmpeg -v error -i "{filePath}" -f null -'
            Examples_CustomCommands = @{
                NVIDIA_GPU = 'ffmpeg -hwaccel cuda -i "{filePath}" -f null -'
                AMD_GPU = 'ffmpeg -hwaccel amf -i "{filePath}" -f null -'
                Intel_GPU = 'ffmpeg -hwaccel qsv -i "{filePath}" -f null -'
            }
        }
        SevenZipUrl = 'https://www.7-zip.org/a/7z2301-extra.zip'
        Performance = @{
            MaxConcurrentJobs = 0
        }
        Language = "en"
        CorruptedFileAction = @{
            Action = "Delete"
            MovePath = "_CorruptedFiles"
        }
        DuplicateFileCheck = @{
            Enabled = $false
        }
        VideoExtensions = @(
            ".mkv", ".mp4", ".avi", ".mov",
            ".wmv", ".flv", ".webm"
        )
        UI = @{
            ShowBanner = $true
        }
    }
}

# Load the configuration
$config = Load-Config

# --- Language & Localization ---
# Function to load language strings from a .json file
function Load-Language {
    param($langCode)
    $langFilePath = Join-Path -Path $PSScriptRoot -ChildPath "$langCode.json"
    # Default to English if the specified language file doesn't exist
    if (-not (Test-Path $langFilePath)) {
        Write-Host "Language file '$langCode.json' not found. Falling back to English." -ForegroundColor Yellow
        $langCode = "en"
        $langFilePath = Join-Path -Path $PSScriptRoot -ChildPath "en.json"
    }
    # If even en.json is missing, exit
    if (-not (Test-Path $langFilePath)) {
        Write-Host "FATAL: Default language file 'en.json' is missing. The script cannot continue." -ForegroundColor Red
        Read-Host "Press Enter to exit."
        exit
    }
    try {
        return Get-Content -Path $langFilePath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "FATAL: Error reading or parsing '$($langFilePath)'. $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to exit."
        exit
    }
}

# Load the language strings based on config
$lang = Load-Language -langCode $config.Language

# Function to get a localized string
function Get-String {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Key,
        [object[]]$FormatArgs
    )
    $template = $lang.$Key
    if ($null -ne $template) {
        if ($FormatArgs) {
            return [string]::Format($template, $FormatArgs)
        } else {
            return $template
        }
    } else {
        # Fallback for missing keys
        return "[$Key NOT FOUND]"
    }
}

# --- Global Variables ---
$corruptedFiles = @()
$deletedFiles = @()
$movedFiles = @()
$duplicateFiles = @{}
$logBuffer = [System.Collections.Generic.List[string]]::new()

# --- Functions ---
# Function to write to a dedicated debug log
function Write-DebugLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logLine = "[$timestamp] $Message"
    Add-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath "debug_log.txt") -Value $logLine
}

# Function to show the script banner
function Show-Banner {
    if ($config.UI.ShowBanner) {
        $bannerInfo = @{
            Name = "Video File Integrity Checker"
            Version = "2.0"
            ReleaseDate = "2023-10-27"
            Link = "https://github.com/your-username/your-repo"
        }
        Write-Host "================================================================"
        Write-Host ((Get-String -Key 'banner_name' -FormatArgs $bannerInfo.Name))
        Write-Host ((Get-String -Key 'banner_version' -FormatArgs $bannerInfo.Version))
        Write-Host ((Get-String -Key 'banner_release_date' -FormatArgs $bannerInfo.ReleaseDate))
        Write-Host ((Get-String -Key 'banner_link' -FormatArgs $bannerInfo.Link))
        Write-Host "================================================================"
        Write-Host ""
    }
}

# Function to find duplicate files based on their hash
function Find-DuplicateFiles {
    param(
        [Parameter(Mandatory=$true)]
        [System.Array]$Files
    )
    Write-Host (Get-String -Key 'starting_duplicate_check') -ForegroundColor Cyan
    $hashes = @{}
    $checkedCount = 0
    $totalCount = $Files.Count

    foreach ($file in $Files) {
        $checkedCount++
        Write-Progress -Activity (Get-String -Key 'starting_duplicate_check') -Status ("{0} / {1}" -f $checkedCount, $totalCount) -PercentComplete (($checkedCount / $totalCount) * 100)

        try {
            $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($hashes.ContainsKey($hash)) {
                $hashes[$hash] += $file.FullName
            } else {
                $hashes[$hash] = @($file.FullName)
            }
        } catch {
            Write-Host "`nWarning: Could not calculate hash for '$($file.FullName)'. Error: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Log "WARN: Could not calculate hash for '$($file.FullName)'. Error: $($_.Exception.Message)"
        }
    }
    Write-Progress -Activity (Get-String -Key 'starting_duplicate_check') -Completed

    # Filter for actual duplicates (more than one file per hash)
    $duplicateSets = $hashes.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

    # Store duplicates in the global variable for reporting
    if ($duplicateSets) {
        foreach ($set in $duplicateSets) {
            $script:duplicateFiles[$set.Name] = $set.Value
        }
    }

    Write-Host (Get-String -Key 'duplicate_check_complete' -FormatArgs $script:duplicateFiles.Keys.Count) -ForegroundColor Green
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
    Write-Host (Get-String -Key 'checking_ffmpeg')
    try {
        # Attempts to find the 'ffmpeg' command
        Get-Command ffmpeg.exe -ErrorAction Stop | Out-Null
        Write-Host (Get-String -Key 'ffmpeg_installed') -ForegroundColor Green
        return $true
    } catch {
        Write-Host (Get-String -Key 'ffmpeg_not_found') -ForegroundColor Yellow
        return $false
    }
}

# Function to install and configure FFmpeg
function Install-FFmpeg {
    Write-Host ""
    if (Test-UserConfirmation -Prompt (Get-String -Key 'prompt_install_ffmpeg')) {
        Write-Log "INFO: User agreed to install FFmpeg."
        Write-Host (Get-String -Key 'starting_ffmpeg_install') -ForegroundColor Cyan

        try {
            $downloadUrl = $config.FFmpegSettings.DownloadUrl
            $tempDir = Join-Path -Path $env:TEMP -ChildPath "ffmpeg_install"
            $zipFile = Join-Path -Path $tempDir -ChildPath "ffmpeg.7z"

            # --- Check and install 7-Zip if necessary ---
            $sevenZipExePath = $null
            try {
                $sevenZipExePath = (Get-Command 7z.exe -ErrorAction Stop).Path
                Write-Log "INFO: 7-Zip is already installed. Using the existing version."
            } catch {
                Write-Host (Get-String -Key '7zip_not_found') -ForegroundColor Yellow
                if (Test-UserConfirmation -Prompt (Get-String -Key 'prompt_install_7zip')) {
                    Write-Log "INFO: User agreed to install portable 7-Zip."
                    $sevenZipDownloadUrl = $config.SevenZipUrl
                    $sevenZipZipFile = Join-Path -Path $tempDir -ChildPath "7z.zip"

                    Write-Host (Get-String -Key 'downloading_7zip')
                    Invoke-WebRequest -Uri $sevenZipDownloadUrl -OutFile $sevenZipZipFile -ErrorAction Stop

                    # Use PowerShell's built-in Expand-Archive for .zip files.
                    Expand-Archive -Path $sevenZipZipFile -DestinationPath $tempDir -Force

                    # Search for the 7-Zip standalone executable ('7za.exe') in the extracted files.
                    $sevenZipExePath = (Get-ChildItem -Path $tempDir -Recurse -Filter "7za.exe").FullName | Select-Object -First 1

                    if (-not ($sevenZipExePath -and (Test-Path $sevenZipExePath))) {
                        throw (Get-String -Key '7zip_exe_not_found')
                    }
                } else {
                    Write-Host (Get-String -Key 'installation_cancelled') -ForegroundColor Yellow
                    return $false
                }
            }

            # Create the temporary folder
            if (-not (Test-Path $tempDir)) {
                New-Item -Path $tempDir -ItemType Directory -ErrorAction Stop | Out-Null
            }

            Write-Host (Get-String -Key 'downloading_ffmpeg' -FormatArgs $downloadUrl)
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -ErrorAction Stop

            Write-Host (Get-String -Key 'extracting_ffmpeg')
            & $sevenZipExePath x "$zipFile" "-o$tempDir" -y | Out-Null

            # Find the 'bin' folder after extraction
            $extractedDir = Get-ChildItem -Path $tempDir -Directory | Where-Object { $_.Name -like "ffmpeg*" }
            $binPath = Join-Path -Path $extractedDir.FullName -ChildPath "bin"

            if (Test-Path $binPath) {
                Write-Host (Get-String -Key 'updating_path')
                # Get the current value of the user's PATH variable
                $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                # Check if the path is not already present to avoid duplicates
                if ($currentPath -notlike "*$binPath*") {
                    $newPath = "$binPath;$currentPath"
                    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                    Write-Host (Get-String -Key 'installation_complete') -ForegroundColor Green
                    Write-Host (Get-String -Key 'restart_powershell') -ForegroundColor Yellow
                    Write-Log "SUCCESS: FFmpeg was installed and the PATH was updated."
                } else {
                    Write-Host (Get-String -Key 'ffmpeg_path_already_in_path') -ForegroundColor Yellow
                }
            } else {
                Write-Host (Get-String -Key 'error_bin_folder_not_found') -ForegroundColor Red
                Write-Log "ERROR: Installation failed. The 'bin' folder was not found."
                exit
            }
            return $true
        } catch {
            Write-Host (Get-String -Key 'error_ffmpeg_install' -FormatArgs $_.Exception.Message) -ForegroundColor Red
            Write-Log "ERROR: FFmpeg installation failed. $($_.Exception.Message)"
            return $false
        }
    } else {
        Write-Host (Get-String -Key 'ffmpeg_install_cancelled') -ForegroundColor Yellow
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
        Write-Host (Get-String -Key 'invalid_input_yn') -ForegroundColor Yellow
    }
}

# Function to open a folder selection window
function Select-Folder {
    # Load the System.Windows.Forms assembly to use the dialog box
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = (Get-String -Key 'select_folder_title')
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
    Write-Host "`n$((Get-String -Key 'stopping_tasks'))" -ForegroundColor Red
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Wait-Job | Out-Null
    $jobs | Remove-Job
    Write-AllLogs
    # Restore default console colors
    $host.ui.rawui.backgroundcolor = "Black"
    $host.ui.rawui.foregroundcolor = "White"
    Write-Host (Get-String -Key 'tasks_stopped') -ForegroundColor Cyan
    exit
}
# --- End of interruption and error handling block ---

# --- Main Script ---
# Clear old debug log
$debugLogPath = Join-Path -Path $PSScriptRoot -ChildPath "debug_log.txt"
if (Test-Path $debugLogPath) {
    Remove-Item $debugLogPath
}

Show-Banner

# Step 0: Check for existing FFmpeg processes
Write-Host (Get-String -Key 'checking_ffmpeg_processes') -ForegroundColor White
$ffmpegProcesses = Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue
if ($ffmpegProcesses) {
    Write-Host (Get-String -Key 'ffmpeg_processes_found' -FormatArgs $ffmpegProcesses.Count) -ForegroundColor Yellow
    if (Test-UserConfirmation -Prompt (Get-String -Key 'prompt_stop_processes')) {
        Write-Host (Get-String -Key 'stopping_ffmpeg_processes') -ForegroundColor Cyan
        Stop-Process -Name "ffmpeg" -Force -ErrorAction SilentlyContinue
        Write-Host (Get-String -Key 'processes_stopped') -ForegroundColor Green
        Write-Log "INFO: User chose to stop running FFmpeg processes."
    } else {
        Write-Host (Get-String -Key 'manual_close_ffmpeg') -ForegroundColor Red
        Write-Host (Get-String -Key 'press_any_key_to_exit')
        Write-Log "INFO: User chose not to stop processes. Exiting script."
        Read-Host -Prompt (Get-String -Key 'press_any_key_to_exit')
        exit
    }
} else {
    Write-Host (Get-String -Key 'no_ffmpeg_processes_found') -ForegroundColor Green
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
Write-Host (Get-String -Key 'folder_select_window_prompt')
$folderPath = Select-Folder
Write-Host ("{0} {1}" -f (Get-String -Key 'selected_folder'), $folderPath)
Write-Host "[DEBUG] Folder selection complete." -ForegroundColor Cyan

# Check if a path was selected
if ([string]::IsNullOrEmpty($folderPath)) {
    Write-Host (Get-String -Key 'selection_cancelled') -ForegroundColor Yellow
    Write-Log "INFO: User cancelled the selection. The script has ended."
    exit
}

# Check if the path exists (less likely with the dialog box)
if (-not (Test-Path -Path $folderPath)) {
    Write-Host (Get-String -Key 'error_path_not_exist' -FormatArgs $folderPath) -ForegroundColor Red
    Write-Log "ERROR: The path '$folderPath' does not exist."
    exit
}

# Step 3: Get the list of video files
Write-Host "[DEBUG] Step 3: Getting video file list..." -ForegroundColor Cyan
$videoFiles = Get-ChildItem -Path $folderPath -File -Recurse | Where-Object {
    $_.Extension -in $config.VideoExtensions
}
Write-Host "[DEBUG] Found $($videoFiles.Count) video files." -ForegroundColor Cyan

Write-Log "INFO: $($videoFiles.Count) video files were detected for analysis."

if ($videoFiles.Count -eq 0) {
    Write-Host (Get-String -Key 'no_video_files_found') -ForegroundColor Yellow
    Write-Log "INFO: No video files found. The script has ended."
    exit
}

# Step 3.5: Optional - Find duplicate files
if ($config.DuplicateFileCheck.Enabled) {
    Write-Host "[DEBUG] Step 3.5: Finding duplicate files..." -ForegroundColor Cyan
    Find-DuplicateFiles -Files $videoFiles
    Write-Host "[DEBUG] Duplicate file check complete." -ForegroundColor Cyan
}

# Step 4: Parallel analysis with dynamic CPU usage control and enhanced UI
Write-Host "[DEBUG] Step 4: Preparing for parallel analysis..." -ForegroundColor Cyan
Clear-Host # Clear the window for a clean start
Write-Host (Get-String -Key 'analysis_in_progress')
Write-Log "INFO: Starting parallel analysis via jobs."

# Set console colors for a better visual experience
$host.ui.rawui.backgroundcolor = "DarkBlue"
$host.ui.rawui.foregroundcolor = "White"
Clear-Host

# Get the maximum number of concurrent jobs from the config
$maxConcurrentJobs = $config.Performance.MaxConcurrentJobs

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
Write-Host (Get-String -Key 'analyzing_files' -FormatArgs $totalFiles)
Write-Host ""
Write-Host "------------------------------------------------"
Write-Host (Get-String -Key 'recently_analyzed_files')

# Main loop
while ($jobsCompleted -lt $totalFiles) {
    Write-DebugLog "Loop start. Jobs completed: $jobsCompleted / $totalFiles. Running jobs: ($($jobs | Where-Object { $_.State -eq 'Running' }).Count)"
    # --- Graceful cancellation ---
    if ($Host.UI.RawUI.KeyAvailable -and ($Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Character -eq 'q')) {
        Write-DebugLog "'q' key pressed. Breaking loop."
        Write-Host "`n$((Get-String -Key 'q_pressed_to_cancel'))" -ForegroundColor Yellow
        break
    }

    # Start new jobs if the number of running jobs is less than the maximum
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -lt $maxConcurrentJobs -and $filesToAnalyze.Count -gt 0) {
        $file = $filesToAnalyze.Dequeue()
        Write-DebugLog "Starting job for file: $($file.FullName)"
        $jobs += Start-Job -ScriptBlock {
            param($filePath, $ffmpegCommand)

            # Build the command by replacing the placeholder
            $commandToRun = $ffmpegCommand.Replace("{filePath}", $filePath)

            # Start the check with FFmpeg
            # We use Invoke-Expression to handle complex commands with arguments
            $result = Invoke-Expression -Command "$commandToRun 2>&1"
            $isCorrupted = (-not [string]::IsNullOrWhiteSpace($result))

            # Return the results
            [PSCustomObject]@{
                FullName = $filePath
                IsCorrupted = $isCorrupted
                FFmpegOutput = $result
            }
        } -ArgumentList @($file.FullName, $config.FFmpegSettings.CustomCommand)
    }

    # Check for completed jobs
    Write-DebugLog "Checking for completed jobs."
    $completedJobs = $jobs | Where-Object { $_.State -eq 'Completed' }

    if ($completedJobs) {
        Write-DebugLog "Found $($completedJobs.Count) completed jobs."
        foreach ($job in $completedJobs) {
            $jobsCompleted++
            Write-DebugLog "Processing completed job for file: $($job.Name)"

            $result = Receive-Job -Job $job -Keep

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
        Write-DebugLog "Removing completed jobs from job list."
        $jobs = $jobs | Where-Object { $_.State -ne 'Completed' }
        $completedJobs | Remove-Job
    }

    # --- UI Refresh Section without flickering ---
    try {
        Write-DebugLog "Starting UI Refresh section."
        # Update console width for responsive UI
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width

        # Update progress bar
        $progressPercentage = ($jobsCompleted / $totalFiles) * 100
        $progressText = (Get-String -Key 'progress_text' -FormatArgs ([math]::Round($progressPercentage, 2)), $jobsCompleted, $totalFiles)

        # Update spinner
        $spinnerIndex = ($spinnerIndex + 1) % $spinner.Count
        $spinnerChar = $spinner[$spinnerIndex]

        [System.Console]::SetCursorPosition(0, $progressLine)
        [System.Console]::Write($progressText + $spinnerChar + (" " * ($consoleWidth - $progressText.Length - 1)))

        # Update the list of recently analyzed files
        $i = 0
        $recentlyAnalyzedFiles | ForEach-Object {
            $statusText = if ($_.IsCorrupted) { (Get-String -Key 'status_corrupted') } else { (Get-String -Key 'status_not_corrupted') }
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
        Write-DebugLog "UI Refresh section complete."
    } catch {
        Write-DebugLog "CRITICAL: Error during UI Refresh. Error: $($_.Exception.ToString())"
    }
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

# Step 5: Final summary and interactive actions
Write-Host ""
Write-Host (Get-String -Key 'analysis_summary')
Write-Host ("{0} {1}" -f (Get-String -Key 'files_analyzed'), $totalFiles)
Write-Host ("{0} {1}" -f (Get-String -Key 'corrupted_files_detected'), $corruptedFiles.Count)

# Interactive actions for corrupted files
if ($corruptedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host (Get-String -Key 'list_of_corrupted_files') -ForegroundColor Red
    $corruptedFiles | ForEach-Object { Write-Host " - $_" }

    Write-Host ""
    $action = $config.CorruptedFileAction.Action
    $confirmationPrompt = ""
    if ($action -eq "Delete") {
        $confirmationPrompt = (Get-String -Key 'prompt_delete_files' -FormatArgs $corruptedFiles.Count)
        Write-Host (Get-String -Key 'warning_irreversible') -ForegroundColor Yellow
    } elseif ($action -eq "Move") {
        $movePath = $config.CorruptedFileAction.MovePath
        # Ensure the move path is absolute
        if (-not ([System.IO.Path]::IsPathRooted($movePath))) {
            $movePath = Join-Path -Path $PSScriptRoot -ChildPath $movePath
        }
        $confirmationPrompt = (Get-String -Key 'prompt_move_files' -FormatArgs $corruptedFiles.Count, $movePath)
        Write-Host (Get-String -Key 'action_move') -ForegroundColor Cyan
    }

    $fileActions = @{}
    if ($confirmationPrompt -and (Test-UserConfirmation -Prompt $confirmationPrompt)) {
        # Create quarantine directory if it doesn't exist
        if ($action -eq "Move") {
            $movePath = $config.CorruptedFileAction.MovePath
            if (-not ([System.IO.Path]::IsPathRooted($movePath))) {
                $movePath = Join-Path -Path $PSScriptRoot -ChildPath $movePath
            }
            if (-not (Test-Path -Path $movePath)) {
                New-Item -Path $movePath -ItemType Directory -Force | Out-Null
            }
        }

        foreach ($file in $corruptedFiles) {
            try {
                if ($action -eq "Delete") {
                    Write-Host (Get-String -Key 'deleting_file' -FormatArgs $file) -ForegroundColor Cyan
                    Remove-Item -Path $file -Recurse -Force -ErrorAction Stop
                    $deletedFiles += $file
                    $fileActions[$file] = (Get-String -Key 'status_deleted')
                    Write-Log "SUCCESS: '$file' was permanently deleted."
                } elseif ($action -eq "Move") {
                    $fileName = Split-Path -Path $file -Leaf
                    $destination = Join-Path -Path $movePath -ChildPath $fileName
                    Write-Host (Get-String -Key 'moving_file' -FormatArgs $file, $destination) -ForegroundColor Cyan
                    Move-Item -Path $file -Destination $destination -Force -ErrorAction Stop
                    $movedFiles += $file
                    $fileActions[$file] = (Get-String -Key 'status_moved')
                    Write-Log "SUCCESS: '$file' was moved to '$destination'."
                }
            } catch {
                $errorMessage = (Get-String -Key 'error_actioning_file' -FormatArgs $action.ToLower(), $file, $_.Exception.Message)
                $fileActions[$file] = (Get-String -Key 'status_failed_to_action' -FormatArgs $action)
                Write-Host $errorMessage -ForegroundColor Red
                Write-Log "ERROR: $errorMessage"
            }
        }
        Write-Log "INFO: User chose to $action files. Summary: $($deletedFiles.Count + $movedFiles.Count) of $($corruptedFiles.Count) corrupted files were actioned."

    } else {
        Write-Host (Get-String -Key 'action_cancelled') -ForegroundColor Cyan
        Write-Log "INFO: User chose not to take any action on corrupted files."
        foreach ($file in $corruptedFiles) {
            $fileActions[$file] = (Get-String -Key 'status_no_action')
        }
    }

    # Final summary with table
    Write-Host ""
    Write-Host (Get-String -Key 'action_summary')
    Write-Host ""

    $table = $corruptedFiles | ForEach-Object {
        [PSCustomObject]@{
            Status = $fileActions[$_]
            Path = $_
        }
    }

    $table | Format-Table -AutoSize
} else {
    Write-Host (Get-String -Key 'no_corrupted_files_found') -ForegroundColor Green
    Write-Log "INFO: No corrupted files were found."
}

# Display duplicate file summary
if ($config.DuplicateFileCheck.Enabled) {
    Write-Host ""
    Write-Host (Get-String -Key 'duplicate_summary_title')

    if ($duplicateFiles.Keys.Count -gt 0) {
        Write-Host (Get-String -Key 'duplicates_found_message')
        Write-Host ""

        foreach ($hash in $duplicateFiles.Keys) {
            Write-Host "  $((Get-String -Key 'hash_header')): $hash" -ForegroundColor Yellow
            foreach ($file in $duplicateFiles[$hash]) {
                Write-Host "    - $file"
            }
            Write-Host ""
        }
    } else {
        Write-Host (Get-String -Key 'no_duplicates_found') -ForegroundColor Green
    }
}

Write-Host ""
Write-Host (Get-String -Key 'script_finished') -ForegroundColor Cyan