# Set console encoding to UTF-8 for special characters (emojis)
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Define global variables for the script
$corruptedFiles = @()
$deletedFiles = @()
$logBuffer = [System.Collections.Generic.List[string]]::new()

# --- Functions ---

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
    $installChoice = Read-Host -Prompt "Do you want the script to install FFmpeg for you? (Y/N)"
    
    if ($installChoice -eq 'o' -or $installChoice -eq 'O' -or $installChoice -eq 'y' -or $installChoice -eq 'Y') {
        Write-Log "INFO: User agreed to install FFmpeg."
        Write-Host "Starting FFmpeg installation..." -ForegroundColor Cyan

        try {
            $downloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-full.7z"
            $tempDir = Join-Path -Path $env:TEMP -ChildPath "ffmpeg_install"
            $zipFile = Join-Path -Path $tempDir -ChildPath "ffmpeg.7z"
            
            # --- Check and install 7-Zip if necessary ---
            $sevenZipExePath = $null
            try {
                $sevenZipExePath = (Get-Command 7z.exe -ErrorAction Stop).Path
                Write-Log "INFO: 7-Zip is already installed. Using the existing version."
            } catch {
                Write-Host "7-Zip was not found on your system." -ForegroundColor Yellow
                $sevenZipChoice = Read-Host -Prompt "Do you want to install a portable version of 7-Zip to extract FFmpeg? (Y/N)"
                if ($sevenZipChoice -eq 'o' -or $sevenZipChoice -eq 'O' -or $sevenZipChoice -eq 'y' -or $sevenZipChoice -eq 'Y') {
                    Write-Log "INFO: User agreed to install portable 7-Zip."
                    $sevenZipDownloadUrl = "https://www.7-zip.org/a/7z2301-extra.zip"
                    $sevenZipZipFile = Join-Path -Path $tempDir -ChildPath "7z.zip"
                    
                    Write-Host "Downloading portable 7-Zip..."
                    Invoke-WebRequest -Uri $sevenZipDownloadUrl -OutFile $sevenZipZipFile -ErrorAction Stop
                    
                    # Cannot use Expand-Archive as it doesn't always support complex .zip files
                    # Using the 7z.exe executable for extraction
                    & "Expand-Archive" -Path $sevenZipZipFile -DestinationPath $tempDir -Force
                    $sevenZipExePath = Join-Path -Path $tempDir -ChildPath "7z.exe"
                    
                    if (-not (Test-Path $sevenZipExePath)) {
                        throw "The 7z.exe executable was not found after extraction."
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
    $jobs | Stop-Job -Force -ErrorAction SilentlyContinue
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

# Step 0: Check for existing FFmpeg processes
Write-Host "Checking for existing FFmpeg processes..." -ForegroundColor White
$ffmpegProcesses = Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue
if ($ffmpegProcesses) {
    Write-Host "Warning: $($ffmpegProcesses.Count) 'ffmpeg.exe' processes were found running." -ForegroundColor Yellow
    $userChoice = Read-Host -Prompt "Do you want to stop these processes to ensure the script runs correctly? (Y/N)"
    
    if ($userChoice -eq 'o' -or $userChoice -eq 'O' -or $userChoice -eq 'y' -or $userChoice -eq 'Y') {
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
    $_.Extension -in ('.mkv', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm') 
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

# Automatically detect the number of logical CPU cores
$logicalCores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
# Set the maximum number of concurrent jobs, leaving one core free, with a cap of 8
$maxConcurrentJobs = [System.Math]::Min([int]($logicalCores - 1), 8)
# Ensure at least one job runs
if ($maxConcurrentJobs -lt 1) { $maxConcurrentJobs = 1 }

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

    # Retrieve completed jobs
    $completedJobs = $jobs | Where-Object { $_.State -eq 'Completed' -and -not $_.HasProcessed }
    
    # Process the results of the completed jobs
    foreach ($job in $completedJobs) {
        $jobsCompleted++
        
        # CHANGEMENT CLÉ : Utiliser l'idiome `$null = $result = ...` pour capturer la sortie du job
        # et s'assurer que rien n'est affiché dans la console.
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
        
        # Mark the job as processed
        $job | Add-Member -MemberType NoteProperty -Name HasProcessed -Value $true -Force
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
    Write-Host "List of corrupted files: " -ForegroundColor Red
    
    $fileActions = @{}
    foreach ($file in $corruptedFiles) {
        Write-Host ""
        Write-Host "Do you want to delete the following corrupted file?" -ForegroundColor Yellow
        Write-Host "-> $file"
        $deleteChoice = Read-Host -Prompt "Delete this file? (Y/N)"
        
        if ($deleteChoice -eq 'o' -or $deleteChoice -eq 'O' -or $deleteChoice -eq 'y' -or $deleteChoice -eq 'Y') {
            try {
                Remove-Item -Path $file -Recurse -Force -ErrorAction Stop
                $deletedFiles += $file
                $fileActions[$file] = "[Deleted]"
                Write-Host "SUCCESS: '$file' was moved to the recycle bin." -ForegroundColor Green
                Write-Log "SUCCESS: '$file' was moved to the recycle bin."
            } catch {
                $fileActions[$file] = "[Failed to delete]"
                Write-Host "Error deleting '$file': $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "ERROR: Failed to delete '$file': $($_.Exception.Message)"
            }
        }
        else {
            $fileActions[$file] = "[Not Deleted]"
            Write-Host "The file '$file' was not deleted." -ForegroundColor Cyan
            Write-Log "INFO: User chose not to delete the file '$file'."
        }
    }
    
    # Final summary with table
    Write-Host ""
    Write-Host "Deletion operation completed."
    Write-Host "Summary of corrupted files:"
    Write-Host ""
    
    # Create and display a formatted table
    $table = $corruptedFiles | ForEach-Object {
        [PSCustomObject]@{
            Status = $fileActions[$_]
            Path = $_
        }
    }
    
    $table | Format-Table -AutoSize
    
    Write-Log "INFO: Final summary: $($deletedFiles.Count) files were deleted out of $($corruptedFiles.Count) corrupted files."
} else {
    Write-Host "No corrupted files were found." -ForegroundColor Green
    Write-Log "INFO: No corrupted files were found."
}

Write-Host ""
Write-Host "Script finished." -ForegroundColor Cyan
