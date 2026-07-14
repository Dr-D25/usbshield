# wipeusb.ps1 — защита от неизвестных USB
# Режимы: delete (быстрое удаление) или wipe (полное затирание)
# Версия 1.0

param(
    [switch]$On,
    [switch]$Off,
    [switch]$Gen,
    [switch]$Show,
    [switch]$Eject,
    [switch]$Demo
)

$WipeMode = "delete"   # <--- измените на "wipe", если нужно затирание
# ------------------------------

$LogFile = "$PSScriptRoot\USBShield.log"
$AllowListFile = "$PSScriptRoot\USBShield.allow"
$ConfigFile = "$PSScriptRoot\USBShield.conf"

if (Test-Path $ConfigFile) {
    $DemoMode = Get-Content $ConfigFile | ConvertFrom-Json
} else {
    $DemoMode = $true
}

if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 1
}

function Save-DemoMode {
    $DemoMode | ConvertTo-Json | Set-Content -Path $ConfigFile
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Get-RemovableDrives {
    Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 2 } | ForEach-Object {
        [PSCustomObject]@{
            DriveLetter   = $_.DeviceID
            SerialNumber  = $_.VolumeSerialNumber
            Size          = $_.Size
            FreeSpace     = $_.FreeSpace
        }
    }
}

function Save-AllowList {
    $drives = Get-RemovableDrives
    $serials = $drives | ForEach-Object { $_.SerialNumber }
    $serials | Set-Content -Path $AllowListFile
    Write-Log "White list updated: $($serials.Count) serial numbers."
    return $serials
}

function Load-AllowList {
    if (Test-Path $AllowListFile) {
        return Get-Content $AllowListFile
    }
    return @()
}

function Show-USB {
    $drives = Get-RemovableDrives
    if (-not $drives) {
        Write-Host "No removable drives found." -ForegroundColor Yellow
        return
    }
    $drives | ForEach-Object { 
        $sizeGB = if ($_.Size) { [math]::Round($_.Size/1GB,2) } else { "unknown" }
        Write-Host "Drive: $($_.DriveLetter)  Serial: $($_.SerialNumber)  Size: $sizeGB GB"
    }
}

function Add-ToAllowList {
    $drives = Get-RemovableDrives
    if (-not $drives) {
        Write-Host "No removable drives found." -ForegroundColor Yellow
        return
    }
    Write-Host "List of removable drives:"
    for ($i=0; $i -lt $drives.Count; $i++) {
        Write-Host "$i. $($drives[$i].DriveLetter)  Serial: $($drives[$i].SerialNumber)"
    }
    $choice = Read-Host "Enter the number of drive to add to white list"
    if ($choice -match '^\d+$' -and $choice -lt $drives.Count) {
        $serial = $drives[$choice].SerialNumber
        $current = Load-AllowList
        if ($current -contains $serial) {
            Write-Host "Drive already in white list." -ForegroundColor Yellow
        } else {
            $current += $serial
            $current | Set-Content -Path $AllowListFile
            Write-Log "Added drive $($drives[$choice].DriveLetter) with serial $serial"
            Write-Host "Drive added." -ForegroundColor Green
        }
    } else {
        Write-Host "Invalid number." -ForegroundColor Red
    }
}

function Delete-Drive {
    param([string]$DriveLetter)
    
    $DriveLetter = $DriveLetter -replace ':$', ''
    $drivePath = $DriveLetter + ":\"

    if (-not (Test-Path $drivePath)) {
        Write-Log "ERROR: Drive $drivePath not accessible."
        return
    }

    Write-Log "Deleting all files and folders on $drivePath ..."
    try {
        Get-ChildItem -Path $drivePath -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "All files and folders deleted from $drivePath"
    } catch {
        Write-Log "ERROR during deletion: $_"
    }
}

function Wipe-Drive {
    param([string]$DriveLetter)
    
    $DriveLetter = $DriveLetter -replace ':$', ''
    $drivePath = $DriveLetter + ":\"

    if (-not (Test-Path $drivePath)) {
        Write-Log "ERROR: Drive $drivePath not accessible."
        return
    }

    Write-Log "Wiping drive $drivePath by writing random data until full..."
    try {
        $chunkSize = 1MB
        $random = New-Object System.Random
        $buffer = New-Object byte[] $chunkSize
        $filePath = Join-Path $drivePath "wipe_temp_$(Get-Random).bin"
        $fileStream = [System.IO.File]::OpenWrite($filePath)
        $totalWritten = 0
        try {
            while ($true) {
                $random.NextBytes($buffer)
                $fileStream.Write($buffer, 0, $buffer.Length)
                $totalWritten += $chunkSize
                if ($totalWritten % (100 * $chunkSize) -eq 0) {
                    Write-Log "Wrote $([math]::Round($totalWritten/1GB,2)) GB to $drivePath"
                }
            }
        } catch [System.IO.IOException] {
            Write-Log "Wipe completed: wrote $([math]::Round($totalWritten/1GB,2)) GB to $drivePath before disk full."
        } finally {
            $fileStream.Close()
            Remove-Item $filePath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "ERROR during wiping: $_"
    }
}

function Start-Monitor {
    $allowList = Load-AllowList
    if (-not $allowList) {
        Write-Host "White list is empty. Creating from current drives..." -ForegroundColor Yellow
        $allowList = Save-AllowList
    }

    Write-Log "Monitoring started (polling). Demo mode: $DemoMode, Mode: $WipeMode"
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Cyan

    $global:previousSerials = Get-RemovableDrives | ForEach-Object { $_.SerialNumber }
    Write-Log "Initial serials: $($global:previousSerials -join ', ')"

    while ($true) {
        Start-Sleep -Seconds 3
        $currentDrives = Get-RemovableDrives
        $currentSerials = $currentDrives | ForEach-Object { $_.SerialNumber }
        $newSerials = $currentSerials | Where-Object { $_ -notin $global:previousSerials }
        if ($newSerials) {
            Write-Log "New drive(s) detected with serial(s): $($newSerials -join ', ')"
            Start-Sleep -Seconds 2
            foreach ($serial in $newSerials) {
                $drive = $currentDrives | Where-Object { $_.SerialNumber -eq $serial }
                if ($drive) {
                    $driveLetter = $drive.DriveLetter
                    if ($allowList -contains $serial) {
                        Write-Log "Drive $driveLetter is in white list, ignoring."
                    } else {
                        Write-Log "UNKNOWN DRIVE! Processing $driveLetter"
                        if (-not $DemoMode) {
                            if ($WipeMode -eq "delete") {
                                Delete-Drive -DriveLetter $driveLetter
                            } else {
                                Wipe-Drive -DriveLetter $driveLetter
                            }
                        } else {
                            Write-Log "DEMO MODE: $WipeMode would be performed on $driveLetter"
                        }
                        $allowList += $serial
                        $allowList | Set-Content -Path $AllowListFile
                    }
                }
            }
        }
        $global:previousSerials = $currentSerials
    }
}

if ($On) {
    if (Test-Path "$AllowListFile.disabled") {
        Rename-Item -Path "$AllowListFile.disabled" -NewName "USBShield.allow"
        Write-Host "Monitoring enabled." -ForegroundColor Green
    } else {
        Write-Host "Monitoring already active or file missing. Use -Gen to create." -ForegroundColor Yellow
    }
    exit
}

if ($Off) {
    if (Test-Path $AllowListFile) {
        Rename-Item -Path $AllowListFile -NewName "USBShield.allow.disabled"
        Write-Host "Monitoring disabled (file renamed)." -ForegroundColor Yellow
    } else {
        Write-Host "Allow list file not found. Monitoring might be already off." -ForegroundColor Yellow
    }
    exit
}

if ($Gen) {
    Save-AllowList
    Write-Host "White list updated." -ForegroundColor Green
    exit
}

if ($Show) {
    Show-USB
    exit
}

if ($Eject) {
    Add-ToAllowList
    exit
}

if ($Demo) {
    $DemoMode = -not $DemoMode
    Save-DemoMode
    Write-Host "Demo mode is now: $DemoMode" -ForegroundColor Cyan
    Write-Log "Demo mode changed to $DemoMode"
    exit
}

Write-Host "Starting monitoring (polling)..." -ForegroundColor Cyan
Start-Monitor
