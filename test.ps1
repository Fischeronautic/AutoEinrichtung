<#
.SYNOPSIS
    Windows 11 Ersteinrichtungs-Skript (Cloud-Version / Zero-Touch)
.DESCRIPTION
    Fuehrt Basis-Einstellungen fuer Windows 11 aus. Fragt Apps am Anfang ab.
    Laeuft per: irm <url> | iex   in einer als Administrator gestarteten PowerShell.
.NOTES
    Ausgaben bewusst ohne Umlaute (Encoding-Sicherheit bei irm|iex).
#>

$ProgressPreference = 'SilentlyContinue'

# ==========================================
# 0. UI-Hilfsfunktionen & Ergebnis-Protokoll
# ==========================================
$script:Fehlerliste  = New-Object System.Collections.Generic.List[string]
$script:Hinweisliste = New-Object System.Collections.Generic.List[string]

function Write-Info    { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
    $script:Fehlerliste.Add($Message)
}
function Add-Hinweis {
    param([string]$Message)
    $script:Hinweisliste.Add($Message)
}

# Setzt einen Registry-Wert und legt den Pfad bei Bedarf an.
# Meldet EHRLICH zurueck, ob es geklappt hat (kein SilentlyContinue im try-Block!).
function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        return $true
    } catch {
        Write-ErrorMsg "Registry '$Name' unter '$Path' fehlgeschlagen: $($_.Exception.Message)"
        return $false
    }
}

# ==========================================
# 1. Admin-Rechte & Internet-Check
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

# Internet-Pruefung: erst HTTP (ICMP wird in vielen Netzen geblockt), dann Ping als Fallback.
function Test-Internetverbindung {
    try {
        $antwort = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($antwort.StatusCode -eq 200) { return $true }
    } catch { }
    try {
        return [bool](Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction Stop)
    } catch {
        return $false
    }
}

Write-Info "Pruefe Internetverbindung..."
while (-not (Test-Internetverbindung)) {
    Write-Host "[-] Keine Internetverbindung! Bitte Netzwerk verbinden." -ForegroundColor Red
    Write-Host "Druecke eine beliebige Taste, um erneut zu pruefen..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host ""
}
Write-Success "Internetverbindung erfolgreich hergestellt."

# Winget-Verfuegbarkeit VOR dem Menue pruefen - sonst waehlt der Techniker Apps,
# die spaeter gar nicht installiert werden koennen.
$wingetVerfuegbar = $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
if (-not $wingetVerfuegbar) {
    Write-Warn "winget wurde nicht gefunden (App Installer fehlt oder ist veraltet)."
    Write-Warn "Die App-Installation wird uebersprungen. App Installer ueber den Microsoft Store nachinstallieren."
    Add-Hinweis "winget fehlte - keine Apps installiert. App Installer im Microsoft Store nachziehen."
}

# ==========================================
# 2. VORAB-ABFRAGE: App-Installation (Zero-Touch Vorbereitung)
# ==========================================
$wingetApps = @{
    1 = @{ Name = "7-Zip";                                       Id = "7zip.7zip" }
    2 = @{ Name = "Google Chrome";                               Id = "Google.Chrome" }
    3 = @{ Name = "Adobe Acrobat Reader";                        Id = "Adobe.Acrobat.Reader.32-bit"; Interactive = $true }
    4 = @{ Name = "Mozilla Firefox";                             Id = "Mozilla.Firefox" }
    5 = @{ Name = "LibreOffice";                                 Id = "TheDocumentFoundation.LibreOffice" }
    6 = @{ Name = "Thunderbird";                                 Id = "Mozilla.Thunderbird" }
    7 = @{ Name = "TeamViewer";                                  Id = "TeamViewer.TeamViewer" }
    8 = @{ Name = "Sumatra PDF (Sehr schnelle Alternative)";     Id = "SumatraPDF.SumatraPDF" }
    9 = @{ Name = "Foxit PDF Reader (Gute Adobe-Alternative)";   Id = "Foxit.FoxitReader" }
}

# Standard-Paket fuer Menuepunkt [1]
$standardApps = @(1, 2, 4, 3)   # 7-Zip, Chrome, Firefox, Adobe Reader (Adobe zuletzt, da interaktiv)

$menuChoice = '0'
$selectedApps = @()

if ($wingetVerfuegbar) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "    APP-INSTALLATIONSMENUE (WINGET)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "[1] Standard-Apps installieren (7-Zip, Chrome, Firefox, Adobe Acrobat Reader)"
    Write-Host "[2] Manuelle Auswahl (Eingabe von Nummern)"
    Write-Host "[0] Keine Apps installieren"
    Write-Host "========================================" -ForegroundColor Magenta

    # Eingabe wird SOFORT validiert - nicht erst 10 Minuten spaeter beim Installieren.
    do {
        $menuChoice = (Read-Host "Bitte waehle eine Option").Trim()
        if ($menuChoice -notin @('0', '1', '2')) {
            Write-Warn "Ungueltige Eingabe. Bitte 0, 1 oder 2 eingeben."
        }
    } while ($menuChoice -notin @('0', '1', '2'))

    if ($menuChoice -eq '1') {
        $selectedApps = $standardApps
    }
    elseif ($menuChoice -eq '2') {
        Write-Host ""
        Write-Host "--- Verfuegbare Apps ---" -ForegroundColor Cyan
        foreach ($key in ($wingetApps.Keys | Sort-Object)) {
            Write-Host "[$key] $($wingetApps[$key].Name)"
        }

        do {
            $eingabe = (Read-Host "Gewuenschte Nummern getrennt durch Leerzeichen (z.B. '1 3 8'), leer = keine Apps").Trim()
            if ([string]::IsNullOrWhiteSpace($eingabe)) {
                Write-Warn "Keine Apps ausgewaehlt."
                $selectedApps = @()
                break
            }

            $selectedApps = @()
            $ungueltig = @()
            foreach ($teil in ($eingabe -split '[\s,;]+' | Where-Object { $_ })) {
                $nummer = 0
                if ([int]::TryParse($teil, [ref]$nummer) -and $wingetApps.ContainsKey($nummer)) {
                    $selectedApps += $nummer
                } else {
                    $ungueltig += $teil
                }
            }
            if ($ungueltig.Count -gt 0) {
                Write-Warn "Ungueltige Eingaben ignoriert: $($ungueltig -join ', ')"
            }
            if ($selectedApps.Count -eq 0) {
                Write-Warn "Keine gueltige Nummer erkannt. Bitte erneut eingeben."
            }
        } while ($selectedApps.Count -eq 0)

        $selectedApps = @($selectedApps | Select-Object -Unique)
    }

    if ($selectedApps.Count -gt 0) {
        Write-Host ""
        Write-Info "Wird installiert: $((($selectedApps | ForEach-Object { $wingetApps[$_].Name })) -join ', ')"
    }
}

Write-Host ""
Write-Success "Auswahl gespeichert! Das Skript arbeitet den Rest nun vollautomatisch ab."
Write-Host "Lehn dich zurueck..." -ForegroundColor Yellow
Start-Sleep -Seconds 2
Write-Host ""

# ==========================================
# 3. System-Basics (BitLocker startet hier im Hintergrund)
# ==========================================
Write-Info "Synchronisiere Windows-Zeit..."
try {
    Start-Service w32time -ErrorAction Stop
    $null = w32tm /resync /force 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Windows-Zeit erfolgreich synchronisiert."
    } else {
        Write-Warn "Zeitsynchronisation lieferte Exitcode $LASTEXITCODE (haeufig unkritisch)."
    }
} catch {
    Write-ErrorMsg "Fehler bei der Zeitsynchronisation: $($_.Exception.Message)"
}

# BitLocker-Cmdlets fehlen auf Windows Home komplett - vorher pruefen statt in den catch laufen.
$bitlockerVerfuegbar = $null -ne (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)

Write-Info "Pruefe BitLocker-Status fuer Laufwerk C:..."
if (-not $bitlockerVerfuegbar) {
    Write-Info "BitLocker-Cmdlets nicht vorhanden (z.B. Windows Home). Uebersprungen."
} else {
    try {
        $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
        if ($null -ne $bl) {
            if ($bl.VolumeStatus -in @("FullyEncrypted", "EncryptionInProgress")) {
                Write-Info "BitLocker ist aktiv. Deaktivierung wird im Hintergrund gestartet..."
                Disable-BitLocker -MountPoint "C:" -ErrorAction Stop | Out-Null
                Write-Success "BitLocker-Entschluesselung laeuft jetzt im Hintergrund! Skript arbeitet weiter..."
            } elseif ($bl.VolumeStatus -eq "DecryptionInProgress") {
                Write-Success "BitLocker-Entschluesselung laeuft bereits im Hintergrund."
            } else {
                Write-Success "BitLocker ist bereits deaktiviert ($($bl.VolumeStatus))."
            }
        }
    } catch {
        Write-ErrorMsg "Fehler bei der BitLocker-Pruefung: $($_.Exception.Message)"
    }
}

# ==========================================
# 4. Windows 11 Anpassungen via Registry & Autostart
# ==========================================
Write-Info "Wende Windows 11 Registry-Anpassungen an..."

$regPathAdvanced = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$okTaskbar = $true
$okTaskbar = (Set-RegValue -Path $regPathAdvanced -Name "TaskbarDa"          -Value 0) -and $okTaskbar   # Widgets
$okTaskbar = (Set-RegValue -Path $regPathAdvanced -Name "TaskbarMn"          -Value 0) -and $okTaskbar   # Chat
$okTaskbar = (Set-RegValue -Path $regPathAdvanced -Name "ShowTaskViewButton" -Value 0) -and $okTaskbar   # Task View
$okTaskbar = (Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0) -and $okTaskbar

if ($okTaskbar) {
    Write-Success "System-Icons (Widgets, Chat, Task View) erfolgreich entfernt."
} else {
    Write-Warn "Taskleisten-Icons nur teilweise entfernt - siehe Fehler oben."
}

$cdmPath    = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
$scoobePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
$okTipps = $true
foreach ($wert in @("SubscribedContent-310093Enabled", "SubscribedContent-338389Enabled", "SubscribedContent-338388Enabled", "SubscribedContent-353698Enabled")) {
    $okTipps = (Set-RegValue -Path $cdmPath -Name $wert -Value 0) -and $okTipps
}
$okTipps = (Set-RegValue -Path $scoobePath -Name "ScoobeSystemSettingEnabled" -Value 0) -and $okTipps

if ($okTipps) {
    Write-Success "Windows-Tipps und Benachrichtigungen deaktiviert."
} else {
    Write-Warn "Windows-Tipps nur teilweise deaktiviert - siehe Fehler oben."
}

# --- EDGE SPEZIAL-BREMSE ---
Write-Info "Deaktiviere Microsoft Edge Autostart & Hintergrundprozesse..."
$edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
$okEdge = $true
$okEdge = (Set-RegValue -Path $edgePolicyPath -Name "StartupBoostEnabled"  -Value 0) -and $okEdge
$okEdge = (Set-RegValue -Path $edgePolicyPath -Name "BackgroundModeEnabled" -Value 0) -and $okEdge
if ($okEdge) {
    Write-Success "Edge Startup-Boost und Hintergrundmodus dauerhaft deaktiviert."
} else {
    Write-Warn "Edge-Richtlinien nur teilweise gesetzt - siehe Fehler oben."
}

Write-Info "Deaktiviere klassische User-Programme aus dem Autostart..."
$startupAppsToDisable = @("OneDrive", "OneDriveSetup", "Teams", "com.squirrel.Teams.Teams", "Spotify", "AdobeARM", "CCXProcess")

$hkcuRun      = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$hklmRun      = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$hkcuApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
$hklmApproved = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"

$disabledValue = [byte[]](0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

foreach ($app in $startupAppsToDisable) {
    if ((Test-Path $hkcuRun) -and (Get-ItemProperty -Path $hkcuRun -Name $app -ErrorAction SilentlyContinue)) {
        if (Set-RegValue -Path $hkcuApproved -Name $app -Value $disabledValue -Type 'Binary') {
            Write-Success "Autostart fuer '$app' (User-Ebene) deaktiviert."
        }
    }
    if ((Test-Path $hklmRun) -and (Get-ItemProperty -Path $hklmRun -Name $app -ErrorAction SilentlyContinue)) {
        if (Set-RegValue -Path $hklmApproved -Name $app -Value $disabledValue -Type 'Binary') {
            Write-Success "Autostart fuer '$app' (System-Ebene) deaktiviert."
        }
    }
}

# Joker-Suche nach versteckten Edge-Autostarts
foreach ($runPath in @($hkcuRun, $hklmRun)) {
    if (Test-Path $runPath) {
        $edgeKeys = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue |
                    Get-Member -MemberType NoteProperty |
                    Where-Object { $_.Name -match "Edge" }
        foreach ($key in $edgeKeys) {
            try {
                Remove-ItemProperty -Path $runPath -Name $key.Name -ErrorAction Stop
                Write-Success "Versteckter Edge-Autostarteintrag ($($key.Name)) geloescht."
            } catch {
                Write-ErrorMsg "Edge-Autostarteintrag '$($key.Name)' konnte nicht geloescht werden: $($_.Exception.Message)"
            }
        }
    }
}

if ((Test-Path $hkcuRun) -and (Get-ItemProperty -Path $hkcuRun -Name "OneDriveSetup" -ErrorAction SilentlyContinue)) {
    try {
        Remove-ItemProperty -Path $hkcuRun -Name "OneDriveSetup" -ErrorAction Stop
        Write-Success "OneDriveSetup komplett aus HKCU Run-Key entfernt."
    } catch {
        Write-ErrorMsg "OneDriveSetup konnte nicht entfernt werden: $($_.Exception.Message)"
    }
}

# ==========================================
# 5. Bloatware-Bereinigung (Muellschlucker)
# ==========================================
Write-Info "Starte Bloatware-Bereinigung (Suche nach Junk-Apps)..."
$bloatwareList = @("McAfee", "WebAdvisor", "Norton", "ExpressVPN", "Dropbox", "TikTok", "Instagram", "Facebook", "Spotify", "WhatsApp")

$uninstallPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

# Provisioned Packages einmal holen - sonst kommt der Muell beim naechsten neuen Profil zurueck.
$provisioned = @()
try {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
} catch {
    Write-Warn "Provisionierte Apps konnten nicht gelesen werden: $($_.Exception.Message)"
}

foreach ($junk in $bloatwareList) {

    # --- Store-Apps (aktuelle + alle vorhandenen Profile) ---
    $appxPakete = @(Get-AppxPackage -AllUsers -Name "*$junk*" -ErrorAction SilentlyContinue)
    foreach ($paket in $appxPakete) {
        try {
            Remove-AppxPackage -Package $paket.PackageFullName -AllUsers -ErrorAction Stop
            Write-Success "$($paket.Name) (Windows App) entfernt."
        } catch {
            Write-ErrorMsg "$($paket.Name) (Windows App) konnte nicht entfernt werden: $($_.Exception.Message)"
        }
    }

    # --- Provisionierte Apps (fuer kuenftige Benutzerkonten) ---
    foreach ($prov in ($provisioned | Where-Object { $_.DisplayName -like "*$junk*" })) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Write-Success "$($prov.DisplayName) aus dem Windows-Image entfernt (kommt bei neuen Konten nicht wieder)."
        } catch {
            Write-ErrorMsg "$($prov.DisplayName) konnte nicht aus dem Image entfernt werden: $($_.Exception.Message)"
        }
    }

    # --- Klassische Desktop-Programme ---
    $desktopApps = @(Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -and $_.DisplayName -like "*$junk*" })

    foreach ($app in $desktopApps) {
        # Nur STILLE Deinstallationen automatisch fahren. Ein blindes
        # cmd /c "<UninstallString>" oeffnet sonst GUI-Fenster und blockiert das Skript.
        $stillerBefehl = $null

        if ($app.QuietUninstallString) {
            $stillerBefehl = $app.QuietUninstallString
        }
        elseif ($app.UninstallString -and $app.UninstallString -match '(\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') {
            # MSI-Paket: laesst sich zuverlaessig still deinstallieren
            $stillerBefehl = "msiexec.exe /x $($Matches[1]) /qn /norestart"
        }

        if ($stillerBefehl) {
            Write-Info "Deinstalliere still: $($app.DisplayName)"
            try {
                # Ganzen Befehl in EIN Argument packen und zusaetzlich klammern:
                # cmd /c "<befehl>" ist die einzige Form, die auch bei Pfaden
                # mit Leerzeichen und eigenen Anfuehrungszeichen sauber laeuft.
                $prozess = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$stillerBefehl`"" -WindowStyle Hidden -PassThru -ErrorAction Stop
                $null = $prozess | Wait-Process -Timeout 600 -ErrorAction SilentlyContinue
                if (-not $prozess.HasExited) {
                    Stop-Process -Id $prozess.Id -Force -ErrorAction SilentlyContinue
                    Write-ErrorMsg "$($app.DisplayName): Deinstallation nach 10 Minuten abgebrochen (Timeout)."
                    Add-Hinweis "$($app.DisplayName) manuell deinstallieren (Timeout)."
                } elseif ($prozess.ExitCode -eq 0 -or $prozess.ExitCode -eq 3010) {
                    Write-Success "$($app.DisplayName) deinstalliert."
                    if ($prozess.ExitCode -eq 3010) { Add-Hinweis "$($app.DisplayName): Neustart erforderlich." }
                } else {
                    Write-ErrorMsg "$($app.DisplayName): Deinstallation fehlgeschlagen (Exitcode $($prozess.ExitCode))."
                    Add-Hinweis "$($app.DisplayName) manuell deinstallieren."
                }
            } catch {
                Write-ErrorMsg "$($app.DisplayName): Deinstallation konnte nicht gestartet werden: $($_.Exception.Message)"
                Add-Hinweis "$($app.DisplayName) manuell deinstallieren."
            }
        }
        elseif ($app.UninstallString) {
            # Kein stiller Weg vorhanden -> NICHT blind starten, sondern am Ende auflisten.
            Write-Warn "$($app.DisplayName) bietet keine stille Deinstallation - wird am Ende zur manuellen Entfernung gelistet."
            Add-Hinweis "$($app.DisplayName) manuell deinstallieren (Systemsteuerung / Hersteller-Removal-Tool)."
        }
    }
}
Write-Success "Bloatware-Pruefung abgeschlossen."

# ==========================================
# 6. App-Installation ausfuehren (Winget)
# ==========================================
function Install-WingetApp {
    param(
        [string]$Id,
        [string]$Name,
        [bool]$Interactive = $false
    )

    Write-Info "Starte Installation von $Name ($Id)..."

    # Achtung: NICHT $args nennen - das ist eine automatische PowerShell-Variable.
    $wgArgs = @('install', '--id', $Id, '-e', '--source', 'winget',
                '--accept-package-agreements', '--accept-source-agreements')
    if ($Interactive) {
        $wgArgs += '--interactive'
    } else {
        $wgArgs += @('--silent', '--disable-interactivity')
    }

    try {
        $ausgabe = & winget.exe @wgArgs 2>&1
        $code = $LASTEXITCODE
    } catch {
        Write-ErrorMsg "$Name : winget konnte nicht gestartet werden: $($_.Exception.Message)"
        return
    }

    # Exitcodes laut winget-Doku:
    #   0            = OK
    #  -1978335135   = 0x8A150061  bereits installiert
    #  -1978335189   = 0x8A15002B  kein Update noetig
    #  -1978334967   = 0x8A150109  Neustart erforderlich
    #  -1978335215   = 0x8A150011  HASH-FEHLER -> das ist ein FEHLER, kein Erfolg!
    switch ($code) {
        0 {
            Write-Success "$Name erfolgreich installiert."
        }
        -1978335135 {
            Write-Success "$Name war bereits installiert."
        }
        -1978335189 {
            Write-Success "$Name ist bereits aktuell."
        }
        -1978334967 {
            Write-Warn "$Name installiert - Neustart erforderlich."
            Add-Hinweis "$Name : Neustart erforderlich."
        }
        default {
            Write-ErrorMsg "$Name wurde NICHT installiert (winget Exitcode $code)."
            $letzteZeilen = @($ausgabe | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 3)
            if ($letzteZeilen.Count -gt 0) {
                Write-Warn "    winget: $(($letzteZeilen -join ' | ').Trim())"
            }
            Add-Hinweis "$Name manuell installieren."
        }
    }
}

if ($selectedApps.Count -gt 0) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "    FUEHRE GEWAEHLTE APP-INSTALLATION AUS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Magenta

    foreach ($nummer in $selectedApps) {
        Install-WingetApp -Id $wingetApps[$nummer].Id `
                          -Name $wingetApps[$nummer].Name `
                          -Interactive ([bool]$wingetApps[$nummer].Interactive)
    }
} else {
    Write-Info "App-Installation wird uebersprungen."
}

# ==========================================
# 7. Taskleisten-Pins setzen (NUR EXPLORER)
# ==========================================
# Windows 11 steuert Taskleisten-Pins ueber LayoutModification.XML
# (CustomTaskbarLayoutCollection / TaskbarPinList) - NICHT ueber JSON.
# Die JSON-Variante mit "taskbarActions" hat nie etwas bewirkt.
Write-Info "Raeume Taskleiste auf und pinne nur den Explorer..."

$layoutXml = @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@

# XML fuer den aktuellen Benutzer UND fuer kuenftige neue Konten (Default-Profil) ablegen.
$layoutZiele = @(
    "$env:LOCALAPPDATA\Microsoft\Windows\Shell\LayoutModification.xml",
    "$env:SystemDrive\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml"
)

$layoutOk = $false
foreach ($ziel in $layoutZiele) {
    try {
        $ordner = Split-Path -Path $ziel -Parent
        if (-not (Test-Path $ordner)) { New-Item -Path $ordner -ItemType Directory -Force -ErrorAction Stop | Out-Null }
        Set-Content -Path $ziel -Value $layoutXml -Encoding UTF8 -Force -ErrorAction Stop
        $layoutOk = $true
    } catch {
        Write-ErrorMsg "Taskleisten-Layout konnte nicht nach '$ziel' geschrieben werden: $($_.Exception.Message)"
    }
}

# Alte, bereits gesetzte Pins des aktuellen Benutzers entfernen.
try {
    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    if (Test-Path $taskbandPath) {
        Remove-Item -Path $taskbandPath -Recurse -Force -ErrorAction Stop
    }
} catch {
    Write-ErrorMsg "Alte Taskleisten-Pins konnten nicht entfernt werden: $($_.Exception.Message)"
}

# Explorer neu starten - und sicherstellen, dass er auch wirklich wieder laeuft.
try {
    Stop-Process -Name explorer -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
        Start-Sleep -Seconds 2
    }
} catch {
    Write-Warn "Explorer-Neustart nicht moeglich: $($_.Exception.Message)"
}

if ($layoutOk) {
    Write-Success "Taskleisten-Layout hinterlegt (nur Explorer angepinnt)."
    Write-Warn "Hinweis: Windows uebernimmt das Layout endgueltig erst nach Ab- und Anmeldung."
    Add-Hinweis "Taskleiste: einmal ab- und wieder anmelden, damit nur der Explorer gepinnt ist."
} else {
    Write-ErrorMsg "Taskleisten-Layout konnte nicht hinterlegt werden."
}

# ==========================================
# 8. Abschluss-Pruefung (BitLocker)
# ==========================================
Write-Host ""
if ($bitlockerVerfuegbar) {
    Write-Info "Warte auf Abschluss der BitLocker-Entschluesselung (falls noch aktiv)..."
    try {
        $blEnd = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop

        if ($null -ne $blEnd -and $blEnd.VolumeStatus -ne "FullyDecrypted") {
            # Timeout: sonst dreht das Skript endlos, wenn die Entschluesselung haengt.
            $timeout    = New-TimeSpan -Hours 3
            $stoppuhr   = [System.Diagnostics.Stopwatch]::StartNew()
            $status     = $blEnd.VolumeStatus

            while ($status -ne "FullyDecrypted" -and $stoppuhr.Elapsed -lt $timeout) {
                Start-Sleep -Seconds 5
                $aktuell = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
                if ($null -eq $aktuell) { break }
                $status = $aktuell.VolumeStatus
                Write-Host -NoNewline "`r[i] Entschluesselung laeuft noch... $($aktuell.EncryptionPercentage)% (seit $([int]$stoppuhr.Elapsed.TotalMinutes) min) "
            }
            $stoppuhr.Stop()
            Write-Host ""

            if ($status -eq "FullyDecrypted") {
                Write-Success "BitLocker ist nun vollstaendig deaktiviert."
            } else {
                Write-ErrorMsg "BitLocker-Entschluesselung nicht abgeschlossen (Status: $status). Bitte manuell pruefen: manage-bde -status C:"
                Add-Hinweis "BitLocker laeuft noch - Status mit 'manage-bde -status C:' pruefen."
            }
        } else {
            Write-Success "BitLocker war bereits vollstaendig deaktiviert."
        }
    } catch {
        Write-Warn "BitLocker-Abschlusspruefung konnte nicht durchgefuehrt werden: $($_.Exception.Message)"
    }
}

# ==========================================
# 9. Ergebnis-Protokoll
# ==========================================
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host " Ersteinrichtung abgeschlossen "                   -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green

if ($script:Fehlerliste.Count -gt 0) {
    Write-Host ""
    Write-Host "FEHLER ($($script:Fehlerliste.Count)):" -ForegroundColor Red
    foreach ($f in $script:Fehlerliste) { Write-Host "  - $f" -ForegroundColor Red }
} else {
    Write-Host ""
    Write-Host "Keine Fehler aufgetreten." -ForegroundColor Green
}

if ($script:Hinweisliste.Count -gt 0) {
    Write-Host ""
    Write-Host "NOCH ZU ERLEDIGEN ($($script:Hinweisliste.Count)):" -ForegroundColor Yellow
    foreach ($h in $script:Hinweisliste) { Write-Host "  - $h" -ForegroundColor Yellow }
}

Write-Host ""
Read-Host "Druecke Enter um das Skript zu beenden..."
