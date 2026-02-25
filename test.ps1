<#
.SYNOPSIS
    Windows 11 Ersteinrichtungs-Skript (Cloud-Version)
.DESCRIPTION
    Fuehrt Basis-Einstellungen fuer Windows 11 aus. Optimiert fuer 'irm | iex'.
#>

# ==========================================
# 0. UI-Hilfsfunktionen fuer farbigen Output
# ==========================================
function Write-Info { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-ErrorMsg { param([string]$Message) Write-Host "[-] $Message" -ForegroundColor Red }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }

# ==========================================
# 1. Admin-Rechte & Internet-Check (CLOUD OPTIMIERT)
# ==========================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-ErrorMsg "FEHLER: Keine Administratorrechte erkannt!"
    Write-Warn "Da dieses Skript direkt aus dem Internet laeuft, kann es sich nicht selbst als Admin neustarten."
    Write-Warn "Bitte druecke auf 'Start', tippe 'PowerShell', waehle 'Als Administrator ausfuehren' und fuege deinen Link erneut ein."
    Write-Host ""
    Read-Host "Druecke Enter, um den Vorgang abzubrechen..."
    return
}

Write-Success "Administratorrechte erfolgreich bestaetigt."

Write-Info "Pruefe Internetverbindung..."
$internetVerfuegbar = $false

while (-not $internetVerfuegbar) {
    if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        $internetVerfuegbar = $true
        Write-Success "Internetverbindung erfolgreich hergestellt."
    } else {
        Write-ErrorMsg "Keine Internetverbindung! Bitte Netzwerk verbinden."
        Write-Host "Druecke eine beliebige Taste, um erneut zu pruefen..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Write-Host "" 
    }
}

# ==========================================
# 2. System-Basics (BitLocker startet hier im Hintergrund)
# ==========================================
Write-Info "Synchronisiere Windows-Zeit..."
try {
    Start-Service w32time -ErrorAction SilentlyContinue
    w32tm /resync /force | Out-Null
    Write-Success "Windows-Zeit erfolgreich synchronisiert."
} catch {
    Write-ErrorMsg "Fehler bei der Zeitsynchronisation: $_"
}

Write-Info "Pruefe BitLocker-Status fuer Laufwerk C:..."
try {
    $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($null -ne $bl) {
        if ($bl.VolumeStatus -in @("FullyEncrypted", "EncryptionInProgress")) {
            Write-Info "BitLocker ist aktiv. Deaktivierung wird im Hintergrund gestartet..."
            Disable-BitLocker -MountPoint "C:" | Out-Null
            Write-Success "BitLocker-Entschluesselung laeuft jetzt im Hintergrund! Skript arbeitet weiter..."
        } elseif ($bl.VolumeStatus -eq "DecryptionInProgress") {
            Write-Success "BitLocker-Entschluesselung laeuft bereits im Hintergrund."
        } else {
            Write-Success "BitLocker ist bereits deaktiviert ($($bl.VolumeStatus))."
        }
    } else {
        Write-Info "Kein BitLocker fuer Laufwerk C: konfiguriert oder Modul nicht geladen."
    }
} catch {
    Write-ErrorMsg "Fehler bei der BitLocker-Pruefung: $_"
}

# ==========================================
# 3. Windows 11 Anpassungen via Registry
# ==========================================
Write-Info "Wende Windows 11 Registry-Anpassungen an..."

try {
    $regPathAdvanced = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path $regPathAdvanced -Name "TaskbarDa" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPathAdvanced -Name "TaskbarMn" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPathAdvanced -Name "ShowTaskViewButton" -Value 0 -Type DWord -ErrorAction SilentlyContinue

    $regPathDsh = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    if (-not (Test-Path $regPathDsh)) { New-Item -Path $regPathDsh -Force | Out-Null }
    Set-ItemProperty -Path $regPathDsh -Name "AllowNewsAndInterests" -Value 0 -Type DWord -ErrorAction Stop

    Write-Success "System-Icons (Widgets, Chat, Task View) erfolgreich entfernt."
} catch {
    Write-ErrorMsg "Fehler beim Deaktivieren der Taskleisten-Icons."
}

try {
    $cdmPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (-not (Test-Path $cdmPath)) { New-Item -Path $cdmPath -Force | Out-Null }
    Set-ItemProperty -Path $cdmPath -Name "SubscribedContent-310093Enabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $cdmPath -Name "SubscribedContent-338389Enabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $cdmPath -Name "SubscribedContent-338388Enabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $cdmPath -Name "SubscribedContent-353698Enabled" -Value 0 -Type DWord

    $scoobePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
    if (-not (Test-Path $scoobePath)) { New-Item -Path $scoobePath -Force | Out-Null }
    Set-ItemProperty -Path $scoobePath -Name "ScoobeSystemSettingEnabled" -Value 0 -Type DWord

    Write-Success "Windows-Tipps und Benachrichtigungen deaktiviert."
} catch {
    Write-ErrorMsg "Fehler beim Deaktivieren der Benachrichtigungen."
}

Write-Info "Deaktiviere klassische User-Programme aus dem Autostart..."
$startupAppsToDisable = @("OneDrive", "OneDriveSetup", "Teams", "com.squirrel.Teams.Teams", "MicrosoftEdgeAutoLaunch", "Spotify", "AdobeARM", "CCXProcess")

$hkcuRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$hklmRun = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$hkcuApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
$hklmApproved = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"

if (-not (Test-Path $hkcuApproved)) { New-Item -Path $hkcuApproved -Force | Out-Null }
if (-not (Test-Path $hklmApproved)) { New-Item -Path $hklmApproved -Force | Out-Null }

$disabledValue = [byte[]](0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

foreach ($app in $startupAppsToDisable) {
    if (Get-ItemProperty -Path $hkcuRun -Name $app -ErrorAction SilentlyContinue) {
        Set-ItemProperty -Path $hkcuApproved -Name $app -Value $disabledValue -Type Binary -ErrorAction SilentlyContinue
        Write-Success "Autostart fuer '$app' (User-Ebene) deaktiviert."
    }
    if (Get-ItemProperty -Path $hklmRun -Name $app -ErrorAction SilentlyContinue) {
        Set-ItemProperty -Path $hklmApproved -Name $app -Value $disabledValue -Type Binary -ErrorAction SilentlyContinue
        Write-Success "Autostart fuer '$app' (System-Ebene) deaktiviert."
    }
}

if (Get-ItemProperty -Path $hkcuRun -Name "OneDriveSetup" -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $hkcuRun -Name "OneDriveSetup" -ErrorAction SilentlyContinue
    Write-Success "OneDriveSetup komplett aus HKCU Run-Key entfernt."
}

# ==========================================
# 4. Bloatware-Bereinigung (Muellschlucker)
# ==========================================
Write-Info "Starte Bloatware-Bereinigung (Suche nach Junk-Apps)..."
$bloatwareList = @("McAfee", "WebAdvisor", "Norton", "ExpressVPN", "Dropbox", "TikTok", "Instagram", "Facebook", "Spotify", "WhatsApp")

foreach ($junk in $bloatwareList) {
    $appx = Get-AppxPackage -Name "*$junk*" -ErrorAction SilentlyContinue
    if ($appx) {
        Write-Info "Entferne Windows-App: $($appx.Name) unsichtbar..."
        $appx | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        Write-Success "$junk (Windows App) erfolgreich entfernt."
    }

    $uninstallPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $desktopApps = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $junk }
    
    foreach ($app in $desktopApps) {
        if ($app.UninstallString) {
            Write-Warn "Desktop-Bloatware gefunden: $($app.DisplayName)"
            Write-Warn "--> Oeffne Deinstallations-Fenster... Bitte auf dem Bildschirm bestaetigen!"
            try {
                cmd.exe /c "$($app.UninstallString)" | Out-Null
                Write-Success "Deinstallations-Aufruf fuer $($app.DisplayName) gesendet."
            } catch {
                Write-ErrorMsg "Fehler beim Aufrufen des Uninstallers fuer $($app.DisplayName)."
            }
        }
    }
}
Write-Success "Bloatware-Pruefung abgeschlossen."

# ==========================================
# 5. App-Installation (Winget)
# ==========================================
$wingetApps = @{
    1 = @{ Name = "7-Zip"; Id = "7zip.7zip" }
    2 = @{ Name = "Google Chrome"; Id = "Google.Chrome" }
    # Hier ist deine neue 32-bit Adobe ID:
    3 = @{ Name = "Adobe Acrobat Reader"; Id = "Adobe.Acrobat.Reader.32-bit"; Interactive = $true }
    4 = @{ Name = "Mozilla Firefox"; Id = "Mozilla.Firefox" }
    5 = @{ Name = "LibreOffice"; Id = "TheDocumentFoundation.LibreOffice" }
    6 = @{ Name = "Thunderbird"; Id = "Mozilla.Thunderbird" }
    7 = @{ Name = "TeamViewer"; Id = "TeamViewer.TeamViewer" }
    8 = @{ Name = "Sumatra PDF (Sehr schnelle, leichte Alternative)"; Id = "SumatraPDF.SumatraPDF" }
    9 = @{ Name = "Foxit PDF Reader (Gute Adobe-Alternative)"; Id = "Foxit.FoxitReader" }
}

function Install-WingetApp {
    param([string]$Id, [string]$Name, [bool]$Interactive = $false)
    Write-Info "Starte Installation von $($Name) ($Id)..."
    try {
        # "--source winget" wurde hier ergaenzt, um den Befehl absolut sicher zu machen:
        if ($Interactive) {
            winget install --id $Id -e --source winget --accept-package-agreements --accept-source-agreements | Out-Null
        } else {
            winget install --id $Id -e --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Null
        }
        
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335215) { 
            Write-Success "$($Name) erfolgreich installiert."
        } else {
            Write-Warn "$($Name) Installation abgeschlossen (Statuscode: $LASTEXITCODE. Moeglicherweise fehlgeschlagen oder erfordert Neustart)."
        }
    } catch {
        Write-ErrorMsg "Fehler bei der Installation von $($Name): $_"
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "    APP-INSTALLATIONSMENUE (WINGET)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "[1] Standard-Apps installieren (7-Zip, Chrome, Firefox, Adobe Acrobat Reader)"
Write-Host "[2] Manuelle Auswahl (Eingabe von Nummern)"
Write-Host "[0] Abbrechen"
Write-Host "========================================" -ForegroundColor Magenta

$menuChoice = Read-Host "Bitte waehle eine Option"

switch ($menuChoice) {
    '1' {
        Write-Info "Automatische Installation der Standard-Apps wird gestartet..."
        Install-WingetApp -Id $wingetApps[1].Id -Name $wingetApps[1].Name -Interactive ([bool]$wingetApps[1].Interactive)
        Install-WingetApp -Id $wingetApps[2].Id -Name $wingetApps[2].Name -Interactive ([bool]$wingetApps[2].Interactive)
        Install-WingetApp -Id $wingetApps[4].Id -Name $wingetApps[4].Name -Interactive ([bool]$wingetApps[4].Interactive)
        Install-WingetApp -Id $wingetApps[3].Id -Name $wingetApps[3].Name -Interactive ([bool]$wingetApps[3].Interactive)
    }
    '2' {
        Write-Host ""
        Write-Host "--- Verfuegbare Apps ---" -ForegroundColor Cyan
        foreach ($key in ($wingetApps.Keys | Sort-Object)) {
            Write-Host "[$key] $($wingetApps[$key].Name)"
        }
        $selection = Read-Host "Bitte gewuenschte Nummern getrennt durch Leerzeichen eingeben (z.B. '1 3 8')"
        
        if (-not [string]::IsNullOrWhiteSpace($selection)) {
            $selectedKeys = $selection -split '\s+'
            foreach ($keyString in $selectedKeys) {
                if ([int]::TryParse($keyString, [ref]$null)) {
                    $num = [int]$keyString
                    if ($wingetApps.ContainsKey($num)) {
                        Install-WingetApp -Id $wingetApps[$num].Id -Name $wingetApps[$num].Name -Interactive ([bool]$wingetApps[$num].Interactive)
                    } else {
                        Write-Warn "Ueberspringe ungueltige Auswahl: $num (Option existiert nicht)"
                    }
                }
            }
        }
    }
    '0' {
        Write-Info "App-Installation wird uebersprungen."
    }
    Default {
        Write-ErrorMsg "Ungueltige Eingabe. App-Installation wird uebersprungen."
    }
}

# ==========================================
# 6. Taskleisten-Pins setzen (NUR EXPLORER)
# ==========================================
Write-Info "Raeume Taskleiste auf und pinne nur den Explorer..."
try {
    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    if (Test-Path $taskbandPath) {
        Remove-Item -Path $taskbandPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $jsonPath = "$env:LOCALAPPDATA\Microsoft\Windows\Shell\LayoutModification.json"
    $layoutJson = @"
{
  "defaultLayoutFile": "LayoutModification.xml",
  "taskbarActions": {
    "command": "add",
    "pins": [
      { "desktopAppId": "Microsoft.Windows.Explorer" }
    ]
  }
}
"@
    Set-Content -Path $jsonPath -Value $layoutJson -Encoding UTF8 -Force
    Stop-Process -Name explorer -Force
    Write-Success "Taskleiste bereinigt. Nur Explorer ist angepinnt."
} catch {
    Write-ErrorMsg "Fehler beim Anpassen der Taskleisten-Pins: $_"
}

# ==========================================
# 7. Abschluss-Pruefung (BitLocker)
# ==========================================
Write-Host ""
Write-Info "Warte auf Abschluss der BitLocker-Entschluesselung (falls noch aktiv)..."
try {
    $blEnd = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
    if ($null -ne $blEnd -and $blEnd.VolumeStatus -in @("DecryptionInProgress", "EncryptionInProgress", "FullyEncrypted")) {
        while ((Get-BitLockerVolume -MountPoint "C:").VolumeStatus -ne "FullyDecrypted") {
            $progress = (Get-BitLockerVolume -MountPoint "C:").EncryptionPercentage
            Write-Host -NoNewline "`r[i] Entschluesselung laeuft noch... $progress% "
            Start-Sleep -Seconds 2
        }
        Write-Host ""
        Write-Success "BitLocker ist nun vollstaendig deaktiviert."
    } else {
        Write-Success "BitLocker war bereits vollstaendig deaktiviert."
    }
} catch {
    Write-Warn "BitLocker-Abschlusspruefung konnte nicht durchgefuehrt werden."
}

Write-Host ""
Write-Success "================================================="
Write-Success " Ersteinrichtung erfolgreich abgeschlossen! "
Write-Success "================================================="
Read-Host "Druecke Enter um das Skript zu beenden..."
