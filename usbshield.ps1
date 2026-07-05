param(
    [switch]$On,
    [switch]$Off,
    [switch]$Gen,
    [switch]$Show,
    [switch]$Eject,
    [switch]$Demo,
    [int]$Interval = 2   # интервал проверки в секундах
)

$LogFile = "$PSScriptRoot\usbkill.log"
$AllowListFile = "$PSScriptRoot\usbkill.allow"
$ConfigFile = "$PSScriptRoot\usbkill.conf"
$Command = "shutdown /s /t 0"

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

function Get-USBLegacyDevices {
    $result = @()
    $devices = Get-PnpDevice -Class USB | Where-Object { $_.Status -eq 'OK' }
    foreach ($dev in $devices) {
        $wmi = Get-WmiObject -Class Win32_PnPEntity | Where-Object { $_.DeviceID -eq $dev.DeviceID }
        $obj = [PSCustomObject]@{
            DeviceID   = $dev.DeviceID
            FriendlyName = $dev.FriendlyName
        }
        $result += $obj
    }
    return $result
}

function Save-AllowList {
    $devices = Get-USBLegacyDevices
    $devices | Export-Clixml -Path $AllowListFile
    Write-Log "White list updated: $($devices.Count) devices."
    return $devices
}

function Load-AllowList {
    if (Test-Path $AllowListFile) {
        return Import-Clixml -Path $AllowListFile
    }
    return $null
}

function Show-USB {
    $devices = Get-USBLegacyDevices
    if (-not $devices) {
        Write-Host "No USB devices found." -ForegroundColor Yellow
        return
    }
    $devices | ForEach-Object { 
        Write-Host "DeviceID: $($_.DeviceID)   Name: $($_.FriendlyName)"
    }
}

function Add-ToAllowList {
    $devices = Get-USBLegacyDevices
    if (-not $devices) {
        Write-Host "No USB devices connected." -ForegroundColor Yellow
        return
    }
    Write-Host "List of USB devices:"
    for ($i=0; $i -lt $devices.Count; $i++) {
        Write-Host "$i. $($devices[$i].FriendlyName) ($($devices[$i].DeviceID))"
    }
    $choice = Read-Host "Enter the number of device to add to white list"
    if ($choice -match '^\d+$' -and $choice -lt $devices.Count) {
        $selected = $devices[$choice]
        $current = Load-AllowList
        if (-not $current) { $current = @() }
        if ($current.DeviceID -contains $selected.DeviceID) {
            Write-Host "Device already in white list." -ForegroundColor Yellow
        } else {
            $current += $selected
            $current | Export-Clixml -Path $AllowListFile
            Write-Log "Added device: $($selected.FriendlyName)"
            Write-Host "Device added." -ForegroundColor Green
        }
    } else {
        Write-Host "Invalid number." -ForegroundColor Red
    }
}

function Start-Monitor {
    $allowList = Load-AllowList
    if (-not $allowList) {
        Write-Host "White list is empty. Creating from current USB devices..." -ForegroundColor Yellow
        $allowList = Save-AllowList
    }

    Write-Log "Monitoring started (polling every $Interval seconds). Demo mode: $DemoMode"
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Cyan

    $allowHash = @{}
    foreach ($dev in $allowList) {
        $allowHash[$dev.DeviceID] = $true
    }

    $previousDevices = $allowList

    while ($true) {
        $currentDevices = Get-USBLegacyDevices
        $newDevices = $currentDevices | Where-Object { 
            -not ($previousDevices.DeviceID -contains $_.DeviceID)
        }

        foreach ($dev in $newDevices) {
            Write-Log "New device detected: $($dev.FriendlyName) ($($dev.DeviceID))"
            if (-not $allowHash.ContainsKey($dev.DeviceID)) {
                Write-Log "UNKNOWN DEVICE! $($dev.FriendlyName)"
                if (-not $DemoMode) {
                    Write-Log "Executing command: $Command"
                    Start-Process -FilePath "shutdown" -ArgumentList "/s /t 0" -WindowStyle Hidden
                } else {
                    Write-Log "DEMO MODE: command NOT executed."
                }
                $allowHash[$dev.DeviceID] = $true
            } else {
                Write-Log "Device is in white list, ignored."
            }
        }

        $previousDevices = $currentDevices
        Start-Sleep -Seconds $Interval
    }
}

if ($On) {
    if (Test-Path "$AllowListFile.disabled") {
        Rename-Item -Path "$AllowListFile.disabled" -NewName "usbkill.allow"
        Write-Host "Monitoring enabled." -ForegroundColor Green
    } else {
        Write-Host "Monitoring already active or file missing. Use -Gen to create." -ForegroundColor Yellow
    }
    exit
}

if ($Off) {
    if (Test-Path $AllowListFile) {
        Rename-Item -Path $AllowListFile -NewName "usbkill.allow.disabled"
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

Write-Host "Starting monitoring (polling every $Interval seconds)..." -ForegroundColor Cyan
Start-Monitor
