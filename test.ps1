<#
.SYNOPSIS
    Windows 11 Ersteinrichtungs-Skript (Cloud-Version / Zero-Touch)
.DESCRIPTION
    Fuehrt Basis-Einstellungen fuer Windows 11 aus. Fragt Modus und Apps am Anfang ab.
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
$script:Diagnoseliste = New-Object System.Collections.Generic.List[string]
$script:AsyncJobs    = New-Object System.Collections.Generic.List[object]

function Write-Info    { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
    $script:Fehlerliste.Add($Message)
}
function Add-Hinweis  { param([string]$Message) $script:Hinweisliste.Add($Message) }
function Add-Diagnose { param([string]$Message) $script:Diagnoseliste.Add($Message) }

# --- Darstellung -------------------------------------------------------
# Bewusst nur ASCII-Zeichen: Rahmenzeichen wie Doppelstriche kommen je nach
# Konsolen-Codepage als Fragezeichen an.
$script:Breite        = 62
$script:Schritte      = @()
$script:SchrittNr     = 0

function Write-Linie { param([string]$Zeichen = '-', [ConsoleColor]$Farbe = 'DarkGray')
    Write-Host ($Zeichen * $script:Breite) -ForegroundColor $Farbe
}

function Write-Banner {
    param([string]$Titel, [string]$Untertitel = '', [ConsoleColor]$Farbe = 'Cyan')
    Write-Host ""
    Write-Linie '=' $Farbe
    Write-Host ("  " + $Titel.ToUpper()) -ForegroundColor $Farbe
    if ($Untertitel) { Write-Host ("  " + $Untertitel) -ForegroundColor DarkGray }
    Write-Linie '=' $Farbe
}

# Legt fest, welche Schritte dieser Durchlauf hat - der Zaehler stimmt
# dadurch auch, wenn nur Apps oder nur die Systemeinrichtung laeuft.
function Set-Ablauf { param([string[]]$Titel) $script:Schritte = $Titel; $script:SchrittNr = 0 }

function Write-Schritt {
    param([string]$Titel)
    $script:SchrittNr++
    $gesamt = [math]::Max(1, $script:Schritte.Count)
    Write-Host ""
    Write-Linie '-' 'DarkCyan'
    Write-Host ("  [Schritt $($script:SchrittNr) von $gesamt]  $Titel") -ForegroundColor White
    Write-Linie '-' 'DarkCyan'
    Write-Progress -Activity "Windows 11 Ersteinrichtung" -Status "Schritt $($script:SchrittNr)/$gesamt - $Titel" `
                   -PercentComplete ([int](100 * ($script:SchrittNr - 1) / $gesamt))
}

function Stop-Fortschritt { Write-Progress -Activity "Windows 11 Ersteinrichtung" -Completed }

# Setzt einen Registry-Wert und legt den Pfad bei Bedarf an.
# Meldet EHRLICH zurueck, ob es geklappt hat (kein SilentlyContinue im try-Block!).
function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord',
        [switch]$Leise
    )
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction Stop
        return $true
    } catch {
        $script:LetzterRegFehler = $_.Exception
        # -Leise: Aufrufer bewertet den Fehlschlag selbst (z.B. wenn eine
        # Richtlinie denselben Zweck bereits erfuellt).
        if (-not $Leise) {
            Write-ErrorMsg "Registry '$Name' unter '$Path' fehlgeschlagen [$($_.Exception.GetType().Name)]: $($_.Exception.Message)"
        }
        return $false
    }
}

# Windows laesst nur EINE MSI-Installation gleichzeitig zu. Laeuft schon eine
# (Windows Update, Bloatware-Deinstallation, Store), scheitert winget mit
# Exitcode 1618. Der Mutex 'Global\_MSIExecute' ist der offizielle Weg, das zu pruefen.
function Test-InstallerFrei {
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting("Global\_MSIExecute")
        return $false
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        # Mutex existiert nicht -> keine Installation aktiv
        return $true
    } catch [System.UnauthorizedAccessException] {
        # Mutex existiert, nur kein Zugriff -> es LAEUFT eine Installation
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Wait-InstallerFrei {
    param([int]$MaxSekunden = 600)
    if (Test-InstallerFrei) { return $true }

    Write-Info "Eine andere Installation laeuft gerade. Warte..."
    $stoppuhr = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stoppuhr.Elapsed.TotalSeconds -lt $MaxSekunden) {
        Start-Sleep -Seconds 10
        if (Test-InstallerFrei) {
            $stoppuhr.Stop()
            Write-Success "Installer wieder frei (nach $([int]$stoppuhr.Elapsed.TotalSeconds) s)."
            return $true
        }
    }
    $stoppuhr.Stop()
    Write-Warn "Nach $MaxSekunden s laeuft immer noch eine andere Installation. Es wird trotzdem weitergemacht."
    return $false
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

Write-Banner "Windows 11 Ersteinrichtung" "Basis-Einstellungen, Bloatware und Apps"
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
# 2. VORAB-ABFRAGE: Modus und Apps
# ==========================================
# Custom = 'Outlook' -> wird nicht ueber ein normales winget-Paket installiert,
# sondern ueber das Office Deployment Tool (siehe Install-Outlook).
# Schluessel bewusst als TEXT: bei [ordered] mit Zahlen-Schluesseln wuerde
# $wingetApps[4] die 4. Position liefern statt den Schluessel 4.
$wingetApps = [ordered]@{
    '1'  = @{ Name = "7-Zip";                                     Id = "7zip.7zip" }
    '2'  = @{ Name = "Google Chrome";                              Id = "Google.Chrome" }
    '3'  = @{ Name = "Adobe Acrobat Reader";                       Id = "Adobe.Acrobat.Reader.32-bit"; Modus = "Standard" }
    '4'  = @{ Name = "Mozilla Firefox (Deutsch)";                  Id = "Mozilla.Firefox.de" }
    '5'  = @{ Name = "LibreOffice";                                Id = "TheDocumentFoundation.LibreOffice" }
    '6'  = @{ Name = "Thunderbird (Deutsch)";                      Id = "Mozilla.Thunderbird.de" }
    '7'  = @{ Name = "TeamViewer";                                 Id = "TeamViewer.TeamViewer" }
    '8'  = @{ Name = "Sumatra PDF (Sehr schnelle Alternative)";    Id = "SumatraPDF.SumatraPDF" }
    '9'  = @{ Name = "Foxit PDF Reader (Gute Adobe-Alternative)";  Id = "Foxit.FoxitReader" }
    '10' = @{ Name = "Outlook klassisch (in vorhandenes M365 nachinstallieren)"; Custom = "Outlook" }
}

# Standard-Paket fuer die Schnellauswahl (Adobe zuletzt, da interaktiv)
$standardApps = @('1', '2', '4', '3')

# App-Auswahl per Klickliste (Out-GridView). Faellt automatisch auf die
# Nummerneingabe zurueck, wenn Out-GridView nicht vorhanden ist oder das
# Fenster nicht geoeffnet werden kann.
function Select-Apps {
    param([System.Collections.Specialized.OrderedDictionary]$Apps)

    $liste = foreach ($key in $Apps.Keys) {
        [pscustomobject]@{
            Nr    = [int]$key
            App   = $Apps[$key].Name
            Paket = $(if ($Apps[$key].Id) { $Apps[$key].Id } else { 'Office Deployment Tool' })
        }
    }

    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        try {
            Write-Info "Auswahlfenster wurde geoeffnet - mehrere Eintraege mit gedrueckter Strg-Taste anklicken, dann OK."
            $auswahl = $liste | Sort-Object Nr |
                       Out-GridView -Title "Apps auswaehlen (Mehrfachauswahl mit Strg) - dann auf OK klicken" -PassThru
            return @($auswahl | ForEach-Object { "$($_.Nr)" })
        } catch {
            Write-Warn "Auswahlfenster nicht verfuegbar ($($_.Exception.Message)) - bitte Nummern eintippen."
        }
    } else {
        Write-Warn "Auswahlfenster nicht verfuegbar - bitte Nummern eintippen."
    }

    # --- Fallback: Nummerneingabe ---
    Write-Host ""
    Write-Host "  Verfuegbare Apps:" -ForegroundColor Cyan
    foreach ($key in $Apps.Keys) {
        Write-Host ("   [{0,2}] {1}" -f $key, $Apps[$key].Name)
    }
    Write-Host ""

    $eingabe = (Read-Host "  Nummern getrennt durch Leerzeichen (z.B. '1 4 10')").Trim()
    if ([string]::IsNullOrWhiteSpace($eingabe)) { return @() }

    $treffer = @()
    $ungueltig = @()
    foreach ($teil in ($eingabe -split '[\s,;]+' | Where-Object { $_ })) {
        $nummer = 0
        # ueber int parsen, damit '04' und '4' gleich behandelt werden
        if ([int]::TryParse($teil, [ref]$nummer) -and $Apps.Contains("$nummer")) {
            $treffer += "$nummer"
        } else {
            $ungueltig += $teil
        }
    }
    if ($ungueltig.Count -gt 0) { Write-Warn "Ungueltige Eingaben ignoriert: $($ungueltig -join ', ')" }
    return @($treffer)
}

$systemSetup  = $true
$selectedApps = @()

# Ohne winget gibt es nichts auszuwaehlen - dann laeuft nur die Systemeinrichtung.
if (-not $wingetVerfuegbar) {
    Write-Warn "Es wird nur die Systemeinrichtung ausgefuehrt (winget fehlt)."
} else {

    Write-Banner "App-Installation" "winget" 'Magenta'
    Write-Host "   [1] Standard-Apps (7-Zip, Chrome, Firefox DE, Adobe Acrobat Reader)"
    Write-Host "   [2] Apps auswaehlen        - Systemeinrichtung laeuft mit"
    Write-Host "   [3] NUR Apps auswaehlen    - Systemeinrichtung wird uebersprungen"
    Write-Host "   [0] Abbrechen"
    Write-Linie '=' 'Magenta'

    # Eingabe wird SOFORT validiert - nicht erst 10 Minuten spaeter beim Installieren.
    do {
        $menuChoice = (Read-Host "  Bitte waehle eine Option").Trim()
        if ($menuChoice -notin @('0', '1', '2', '3')) { Write-Warn "Ungueltige Eingabe. Bitte 0, 1, 2 oder 3 eingeben." }
    } while ($menuChoice -notin @('0', '1', '2', '3'))

    if ($menuChoice -eq '0') {
        Write-Info "Abgebrochen. Es wurde nichts veraendert."
        return
    }

    # Nur bei [3] wird die Systemeinrichtung uebersprungen.
    $systemSetup = ($menuChoice -ne '3')

    if ($menuChoice -eq '1') {
        $selectedApps = $standardApps
    }
    else {
        do {
            $selectedApps = @(Select-Apps -Apps $wingetApps | Select-Object -Unique)

            if ($selectedApps.Count -eq 0) {
                if ($menuChoice -eq '3') {
                    # Ohne Apps und ohne Systemeinrichtung gaebe es nichts zu tun.
                    Write-Warn "Bei 'Nur Apps' muss mindestens eine App gewaehlt werden."
                } else {
                    Write-Warn "Keine Apps ausgewaehlt - es laeuft nur die Systemeinrichtung."
                    break
                }
            }
        } while ($selectedApps.Count -eq 0)
    }

    if ($selectedApps.Count -gt 0) {
        Write-Host ""
        Write-Info "Wird installiert: $((($selectedApps | ForEach-Object { $wingetApps[$_].Name })) -join ', ')"
    }
    if (-not $systemSetup) {
        Write-Info "Systemeinrichtung wird uebersprungen - es werden nur Apps installiert."
    }
}

# Schrittliste passend zum gewaehlten Modus - der Zaehler stimmt dadurch
# auch, wenn nur Apps oder nur die Systemeinrichtung laeuft.
$ablauf = @()
if ($systemSetup)              { $ablauf += 'Zeit und BitLocker' }
if ($systemSetup)              { $ablauf += 'Windows-Anpassungen' }
if ($systemSetup)              { $ablauf += 'Bloatware-Bereinigung' }
if ($selectedApps.Count -gt 0) { $ablauf += 'App-Installation' }
if ($systemSetup)              { $ablauf += 'Taskleiste' }
if ($systemSetup)              { $ablauf += 'BitLocker-Abschluss' }
$ablauf += 'Zusammenfassung'
Set-Ablauf $ablauf

Write-Host ""
Write-Success "Auswahl gespeichert! Das Skript arbeitet den Rest nun weitgehend automatisch ab."
Start-Sleep -Seconds 2
Write-Host ""

# ==========================================
# 3. System-Basics (BitLocker startet hier im Hintergrund)
# ==========================================
$bitlockerVerfuegbar = $false

if ($systemSetup) {
    Write-Schritt "Zeit und BitLocker"
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
}

# ==========================================
# 4. Windows 11 Anpassungen via Registry & Autostart
# ==========================================
if ($systemSetup) {
    Write-Schritt "Windows-Anpassungen"
    Write-Info "Wende Windows 11 Registry-Anpassungen an..."

    $regPathAdvanced = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

    # Widgets zuerst ueber die Richtlinie - das ist der von Microsoft
    # unterstuetzte Weg und wirkt systemweit.
    $okWidgets = Set-RegValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0

    $okTaskbar = $true
    $okTaskbar = (Set-RegValue -Path $regPathAdvanced -Name "TaskbarMn"          -Value 0) -and $okTaskbar   # Chat
    $okTaskbar = (Set-RegValue -Path $regPathAdvanced -Name "ShowTaskViewButton" -Value 0) -and $okTaskbar   # Task View

    # TaskbarDa (Widgets-Button des Benutzers) wird seit Windows 11 24H2 vom
    # UserChoice Protection Driver (UCPD) blockiert - der Schreibversuch endet
    # mit UnauthorizedAccessException. UCPD dafuer abzuschalten waere
    # unverhaeltnismaessig, der Treiber schuetzt auch Standard-Apps und
    # Dateizuordnungen. Solange die Richtlinie oben sitzt, wird der Wert
    # ohnehin nicht gebraucht.
    if (-not (Set-RegValue -Path $regPathAdvanced -Name "TaskbarDa" -Value 0 -Leise)) {
        if ($okWidgets) {
            Write-Info "TaskbarDa ist von Windows gesperrt (UCPD) - nicht noetig, die Widgets-Richtlinie greift bereits."
        } else {
            Write-ErrorMsg "Widgets konnten weder per Richtlinie noch ueber TaskbarDa deaktiviert werden."
            $okTaskbar = $false
        }
        if ($script:LetzterRegFehler) {
            Add-Diagnose "TaskbarDa gesperrt [$($script:LetzterRegFehler.GetType().Name)]: $($script:LetzterRegFehler.Message)"
        }
    }

    if ($okTaskbar -and $okWidgets) {
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
    $okEdge = (Set-RegValue -Path $edgePolicyPath -Name "StartupBoostEnabled"   -Value 0) -and $okEdge
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
}

# ==========================================
# 5. Bloatware-Bereinigung (Muellschlucker)
# ==========================================
if ($systemSetup) {
    Write-Schritt "Bloatware-Bereinigung"
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

            # DIAGNOSE: exakte Uninstall-Daten protokollieren. Damit laesst sich
            # spaeter der wirklich stille Befehl fest einbauen, statt zu raten.
            Add-Diagnose ("Name='{0}' | Version='{1}' | Publisher='{2}'" -f $app.DisplayName, $app.DisplayVersion, $app.Publisher)
            Add-Diagnose ("    UninstallString      = {0}" -f $(if ($app.UninstallString) { $app.UninstallString } else { '<leer>' }))
            Add-Diagnose ("    QuietUninstallString = {0}" -f $(if ($app.QuietUninstallString) { $app.QuietUninstallString } else { '<leer>' }))

            # Nur STILLE Deinstallationen synchron fahren. Ein blindes
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
                # Kein stiller Weg (typisch McAfee/Norton): Fenster im HINTERGRUND oeffnen
                # und weiterarbeiten. Der Techniker klickt es nebenbei durch.
                Write-Warn "$($app.DisplayName): keine stille Deinstallation moeglich - Fenster wird geoeffnet, Skript laeuft weiter."
                try {
                    $prozess = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($app.UninstallString)`"" -PassThru -ErrorAction Stop
                    $script:AsyncJobs.Add([pscustomobject]@{ Name = $app.DisplayName; Prozess = $prozess })
                    Add-Hinweis "$($app.DisplayName): Deinstallationsfenster wurde geoeffnet - bitte durchklicken."
                } catch {
                    Write-ErrorMsg "$($app.DisplayName): Deinstallation konnte nicht gestartet werden: $($_.Exception.Message)"
                    Add-Hinweis "$($app.DisplayName) manuell deinstallieren."
                }
            }
        }
    }
    Write-Success "Bloatware-Pruefung abgeschlossen (offene Fenster laufen im Hintergrund weiter)."
}

# ==========================================
# 6. App-Installation (Winget)
# ==========================================

# Prueft nach der Installation, ob das Paket wirklich da ist.
# winget list liefert Exitcode 0, wenn das Paket gefunden wurde.
function Test-AppInstalliert {
    param([string]$Id)
    try {
        $null = & winget.exe list --exact --id $Id --accept-source-agreements 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-WingetApp {
    param(
        [string]$Id,
        [string]$Name,
        [ValidateSet('Still', 'Standard', 'Interaktiv')]
        [string]$Modus = 'Still',
        [int]$Versuche = 3
    )

    # Achtung: NICHT $args nennen - das ist eine automatische PowerShell-Variable.
    $wgArgs = @('install', '--id', $Id, '-e', '--source', 'winget',
                '--accept-package-agreements', '--accept-source-agreements')
    switch ($Modus) {
        'Still'      { $wgArgs += @('--silent', '--disable-interactivity') }
        'Interaktiv' { $wgArgs += '--interactive' }
        # 'Standard': weder --silent noch --interactive - so lief das Skript
        # urspruenglich. winget waehlt dann selbst 'SilentWithProgress'.
        # Adobe Reader braucht mit erzwungenem --silent auffaellig lange.
    }

    for ($versuch = 1; $versuch -le $Versuche; $versuch++) {

        if ($versuch -eq 1) {
            Write-Info "Starte Installation von $Name ($Id)..."
        } else {
            Write-Info "Neuer Versuch ($versuch von $Versuche) fuer $Name..."
        }

        # Nur eine MSI-Installation gleichzeitig - sonst Exitcode 1618.
        $null = Wait-InstallerFrei -MaxSekunden 600

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
        #  -1978335215   = 0x8A150011  HASH-FEHLER -> Download kaputt, Wiederholung sinnvoll
        #   1618         = MSI: andere Installation laeuft
        switch ($code) {
            0            { Write-Success "$Name erfolgreich installiert."; return }
            -1978335135  { Write-Success "$Name war bereits installiert.";  return }
            -1978335189  { Write-Success "$Name ist bereits aktuell.";      return }
            -1978334967  {
                Write-Warn "$Name installiert - Neustart erforderlich."
                Add-Hinweis "$Name : Neustart erforderlich."
                return
            }
        }

        # Ab hier: Fehlversuch
        $letzteZeilen = @($ausgabe | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 3)
        $meldung = ($letzteZeilen -join ' | ').Trim()

        if ($versuch -lt $Versuche) {
            $wartezeit = 15 * $versuch
            Write-Warn "$Name : Versuch $versuch fehlgeschlagen (Exitcode $code). Neuer Versuch in $wartezeit s..."
            if ($meldung) { Write-Warn "    winget: $meldung" }
            Start-Sleep -Seconds $wartezeit
        } else {
            # Letzte Chance: vielleicht ist die App trotz krummem Exitcode da.
            if (Test-AppInstalliert -Id $Id) {
                Write-Success "$Name ist installiert (winget meldete Exitcode $code, Pruefung sagt aber: vorhanden)."
            } else {
                Write-ErrorMsg "$Name wurde nach $Versuche Versuchen NICHT installiert (letzter Exitcode $code)."
                if ($meldung) { Write-Warn "    winget: $meldung" }
                Add-Hinweis "$Name manuell installieren."
            }
        }
    }
}

# Outlook laesst sich nicht als eigenstaendiges winget-Paket nachziehen.
# Neue Geraete haben bereits eine Click-to-Run-Installation (Word/Excel/PowerPoint),
# nur Outlook fehlt. Deshalb: vorhandene Konfiguration aus der Registry lesen und
# Outlook ueber das Office Deployment Tool in genau diese Installation nachtragen.
#
# WICHTIG: --override ERSETZT die Installer-Argumente. Nur '/configure <xml>' ist
# hier gueltig - ein 'Language=de-de' allein wuerde nichts bewirken.
function Install-Outlook {
    Write-Info "Installiere klassisches Outlook in die vorhandene Microsoft-365-Installation..."

    # Beide Registry-Sichten pruefen: laeuft das Skript in einer 32-Bit-PowerShell,
    # zeigt HKLM:\SOFTWARE auf WOW6432Node und der echte Key bleibt unsichtbar.
    $c2rPfad = @(
        "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $c2rPfad) {
        # Nachsehen, ob ueberhaupt irgendein Office vorhanden ist - das
        # unterscheidet 'leere Maschine' von 'Office da, aber unlesbar'.
        $officeSpuren = @(Get-ItemProperty @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
            ) -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Microsoft 365|Microsoft Office' } |
            Select-Object -ExpandProperty DisplayName -Unique)

        if ($officeSpuren.Count -gt 0) {
            Write-ErrorMsg "Office ist installiert, aber die Click-to-Run-Konfiguration fehlt. Outlook kann nicht nachgetragen werden."
            Write-Warn "Gefundene Office-Eintraege: $($officeSpuren -join ', ')"
            Add-Diagnose "Kein ClickToRun\Configuration-Key, aber Office vorhanden: $($officeSpuren -join ' | ')"
            Add-Hinweis "Outlook: Office-Installation pruefen (evtl. MSI-Version statt Click-to-Run)."
        } else {
            Write-ErrorMsg "Auf diesem Geraet ist kein Office installiert. Outlook laesst sich nur in eine vorhandene Microsoft-365-Installation nachtragen."
            Write-Info "Auf einer frischen VM ohne Office ist das das erwartete Verhalten."
            Add-Diagnose "Weder ClickToRun-Key noch Office-Eintraege gefunden - Geraet ohne Office."
            Add-Hinweis "Outlook: erst Office ueber das Kundenkonto installieren, dann dieses Skript nochmal mit Punkt 10 starten."
        }
        return
    }

    $cfg = Get-ItemProperty -Path $c2rPfad -ErrorAction SilentlyContinue

    # Bei mehreren Produkten (z.B. plus Visio/Project) das Hauptprodukt nehmen.
    $produkt = $null
    if ($cfg.ProductReleaseIds) {
        $produkt = @($cfg.ProductReleaseIds -split ',' |
                     ForEach-Object { $_.Trim() } |
                     Where-Object { $_ -and $_ -notmatch 'Visio|Project' }) | Select-Object -First 1
    }
    if (-not $produkt) {
        Write-ErrorMsg "Office-Produkt-ID konnte nicht aus der Registry gelesen werden."
        Add-Diagnose "ClickToRun\Configuration: ProductReleaseIds ist leer oder unlesbar."
        Add-Hinweis "Outlook manuell nachinstallieren."
        return
    }

    $sprache   = if ($cfg.ClientCulture) { $cfg.ClientCulture } else { "de-de" }
    $plattform = if ($cfg.Platform -eq "x86") { "32" } else { "64" }

    Write-Info "Gefunden: Produkt=$produkt, Sprache=$sprache, Plattform=${plattform}-Bit"
    Add-Diagnose "Office C2R: ProductReleaseIds='$($cfg.ProductReleaseIds)' ClientCulture='$($cfg.ClientCulture)' Platform='$($cfg.Platform)'"

    # Bewusst OHNE ExcludeApp: ein ExcludeApp wuerde die bereits vorhandenen
    # Programme (Word/Excel/PowerPoint) aus der Installation ENTFERNEN.
    # Ohne Ausschluesse wird nur ergaenzt, was noch fehlt - also Outlook.
    $officeXml = @"
<Configuration>
  <Add OfficeClientEdition="$plattform">
    <Product ID="$produkt">
      <Language ID="$sprache" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
</Configuration>
"@

    # Pfad OHNE Leerzeichen - erspart Anfuehrungszeichen-Aerger beim --override.
    $xmlPfad = Join-Path $env:SystemRoot "Temp\autoeinrichtung_outlook.xml"
    try {
        Set-Content -Path $xmlPfad -Value $officeXml -Encoding UTF8 -Force -ErrorAction Stop
    } catch {
        Write-ErrorMsg "Office-Konfiguration konnte nicht geschrieben werden: $($_.Exception.Message)"
        return
    }

    $null = Wait-InstallerFrei -MaxSekunden 900

    Write-Info "Office Deployment Tool laeuft - das kann einige Minuten dauern (Download)."
    try {
        $ausgabe = & winget.exe install --id Microsoft.Office -e --source winget `
                      --accept-package-agreements --accept-source-agreements `
                      --override "/configure $xmlPfad" 2>&1
        $code = $LASTEXITCODE
    } catch {
        Write-ErrorMsg "Outlook: winget konnte nicht gestartet werden: $($_.Exception.Message)"
        return
    }

    Remove-Item -Path $xmlPfad -Force -ErrorAction SilentlyContinue

    if ($code -eq 0) {
        Write-Success "Outlook wurde nachinstalliert (Sprache: $sprache)."
        Add-Hinweis "Outlook: beim ersten Start meldet sich der Kunde mit seinem Microsoft-Konto an."
    } else {
        Write-ErrorMsg "Outlook-Nachinstallation fehlgeschlagen (Exitcode $code)."
        $letzteZeilen = @($ausgabe | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 5)
        if ($letzteZeilen.Count -gt 0) { Write-Warn "    Ausgabe: $(($letzteZeilen -join ' | ').Trim())" }
        Add-Hinweis "Outlook manuell nachinstallieren (Office-Konto -> Apps verwalten)."
        Add-Diagnose "Outlook-Installation Exitcode $code bei Produkt '$produkt', Sprache '$sprache', Plattform '$plattform'."
    }
}

if ($selectedApps.Count -gt 0) {
    Write-Schritt "App-Installation"
    Write-Info "Wird installiert: $((($selectedApps | ForEach-Object { $wingetApps[$_].Name })) -join ', ')"

    # Offene GUI-Deinstallationen (McAfee & Co.) zuerst abwarten - sonst
    # blockieren sie die App-Installation mit MSI-Exitcode 1618.
    if ($script:AsyncJobs.Count -gt 0) {
        $offene = @($script:AsyncJobs | Where-Object { -not $_.Prozess.HasExited })
        if ($offene.Count -gt 0) {
            Write-Warn "Es laufen noch Deinstallations-Fenster: $(($offene.Name) -join ', ')"
            Write-Warn "Bitte diese jetzt fertig durchklicken - danach geht es automatisch weiter."
            foreach ($job in $offene) {
                $null = $job.Prozess | Wait-Process -Timeout 900 -ErrorAction SilentlyContinue
                if ($job.Prozess.HasExited) {
                    Write-Success "$($job.Name): Deinstallationsfenster geschlossen."
                } else {
                    Write-Warn "$($job.Name): Fenster nach 15 Minuten noch offen - es wird trotzdem weitergemacht."
                    Add-Hinweis "$($job.Name): Deinstallation pruefen."
                }
            }
        }
    }

    # Quellen aktualisieren - auf frisch aufgesetzten Geraeten ist der
    # winget-Index oft veraltet, was zu sporadischen Fehlschlaegen fuehrt.
    Write-Info "Aktualisiere winget-Paketquellen..."
    # Achtung: 'source update' kennt KEIN --accept-source-agreements.
    # Der Schalter fuehrt zu 0x8A150002 (ungueltige Argumente).
    $null = & winget.exe source update --disable-interactivity 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Paketquellen aktualisiert."
    } else {
        Write-Warn "winget source update lieferte Exitcode $LASTEXITCODE (wird ignoriert)."
    }

    foreach ($nummer in $selectedApps) {
        $app = $wingetApps[$nummer]
        if ($app.Custom -eq "Outlook") {
            Install-Outlook
        } else {
            $modus = if ($app.Modus) { $app.Modus } else { 'Still' }
            Install-WingetApp -Id $app.Id -Name $app.Name -Modus $modus
        }
    }
} elseif ($wingetVerfuegbar) {
    Write-Info "Keine Apps ausgewaehlt - App-Installation wird uebersprungen."
}

# ==========================================
# 7. Taskleisten-Pins setzen (NUR EXPLORER)
# ==========================================
# Windows 11 steuert Taskleisten-Pins ueber LayoutModification.XML
# (CustomTaskbarLayoutCollection / TaskbarPinList) - NICHT ueber JSON.
# Die JSON-Variante mit "taskbarActions" hat nie etwas bewirkt.
if ($systemSetup) {
    Write-Schritt "Taskleiste"
    Write-Info "Raeume Taskleiste auf und setze die Pins..."

    # Pin-Liste dynamisch aufbauen: Explorer immer, Browser nur wenn wirklich
    # installiert - ein Pin auf eine fehlende Verknuepfung wird ignoriert und
    # laesst die Taskleiste luecken.
    $pinMuster = @('Google Chrome', 'Firefox')
    $startMenues = @(
        @{ Basis = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"; Var = '%ProgramData%\Microsoft\Windows\Start Menu\Programs' },
        @{ Basis = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs";     Var = '%APPDATA%\Microsoft\Windows\Start Menu\Programs' }
    )

    $pinZeilen = New-Object System.Collections.Generic.List[string]
    $pinNamen  = New-Object System.Collections.Generic.List[string]
    $pinZeilen.Add('        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />')
    $pinNamen.Add('Explorer')

    foreach ($muster in $pinMuster) {
        foreach ($sm in $startMenues) {
            if (-not (Test-Path $sm.Basis)) { continue }
            $kandidaten = @(Get-ChildItem -Path $sm.Basis -Filter '*.lnk' -ErrorAction SilentlyContinue |
                            Where-Object { $_.BaseName -like "$muster*" })

            # Exakter Treffer zuerst: sonst gewinnt 'Firefox Private Browsing.lnk',
            # weil Get-ChildItem alphabetisch liefert und das Leerzeichen vor
            # dem Punkt sortiert.
            $lnk = $kandidaten | Where-Object { $_.BaseName -eq $muster } | Select-Object -First 1
            if (-not $lnk) {
                $lnk = $kandidaten |
                       Where-Object { $_.BaseName -notmatch '(?i)privat|private|inprivate|uninstall|deinstall' } |
                       Sort-Object { $_.BaseName.Length } |
                       Select-Object -First 1
            }

            if ($lnk) {
                $pfad = ("$($sm.Var)\$($lnk.Name)") -replace '&', '&amp;'
                $pinZeilen.Add("        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$pfad`" />")
                $pinNamen.Add($lnk.BaseName)
                Write-Info "Taskleiste: '$($lnk.BaseName)' wird angepinnt."
                break
            }
        }
    }

    $layoutXml = @"
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
$($pinZeilen -join "`r`n")
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@

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
        Write-Success "Taskleisten-Layout hinterlegt: $($pinNamen -join ', ')."
        Write-Warn "Hinweis: Windows uebernimmt das Layout endgueltig erst nach Ab- und Anmeldung."
        Add-Hinweis "Taskleiste: einmal ab- und wieder anmelden, dann sind angepinnt: $($pinNamen -join ', ')."
    } else {
        Write-ErrorMsg "Taskleisten-Layout konnte nicht hinterlegt werden."
    }
}

# ==========================================
# 8. Abschluss-Pruefung (BitLocker)
# ==========================================
if ($systemSetup) {
    Write-Schritt "BitLocker-Abschluss"
  if (-not $bitlockerVerfuegbar) {
    Write-Info "BitLocker-Cmdlets nicht vorhanden - nichts zu pruefen."
  } else {
    Write-Info "Warte auf Abschluss der BitLocker-Entschluesselung (falls noch aktiv)..."
    try {
        $blEnd = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop

        if ($null -ne $blEnd -and $blEnd.VolumeStatus -ne "FullyDecrypted") {
            # Timeout: sonst dreht das Skript endlos, wenn die Entschluesselung haengt.
            $timeout  = New-TimeSpan -Hours 3
            $stoppuhr = [System.Diagnostics.Stopwatch]::StartNew()
            $status   = $blEnd.VolumeStatus

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
}

# ==========================================
# 9. Ergebnis-Protokoll
# ==========================================
Write-Schritt "Zusammenfassung"
Stop-Fortschritt

$abschlussFarbe = if ($script:Fehlerliste.Count -gt 0) { 'Yellow' } else { 'Green' }
$abschlussText  = if ($script:Fehlerliste.Count -gt 0) {
    "Ersteinrichtung beendet - $($script:Fehlerliste.Count) Punkt(e) haben nicht geklappt"
} else {
    "Ersteinrichtung erfolgreich abgeschlossen"
}
Write-Banner $abschlussText "" $abschlussFarbe

if ($script:Fehlerliste.Count -gt 0) {
    Write-Host ""
    Write-Host "  FEHLER ($($script:Fehlerliste.Count))" -ForegroundColor Red
    Write-Linie '-' 'Red'
    foreach ($f in $script:Fehlerliste) { Write-Host "   - $f" -ForegroundColor Red }
} else {
    Write-Host ""
    Write-Host "  Keine Fehler aufgetreten." -ForegroundColor Green
}

if ($script:Hinweisliste.Count -gt 0) {
    Write-Host ""
    Write-Host "  NOCH ZU ERLEDIGEN ($($script:Hinweisliste.Count))" -ForegroundColor Yellow
    Write-Linie '-' 'DarkYellow'
    foreach ($h in $script:Hinweisliste) { Write-Host "   - $h" -ForegroundColor Yellow }
}

if ($script:Diagnoseliste.Count -gt 0) {
    Write-Host ""
    Write-Host "  DIAGNOSE (fuer die Skript-Pflege)" -ForegroundColor Magenta
    Write-Linie '-' 'DarkGray'
    foreach ($d in $script:Diagnoseliste) { Write-Host "   $d" -ForegroundColor Gray }
}

# Komplettes Protokoll als Datei ablegen - lange Fehlermeldungen sind in der
# Konsole oft abgeschnitten oder von Installationsfenstern verdeckt.
$protokoll = New-Object System.Collections.Generic.List[string]
$protokoll.Add("AutoEinrichtung - Protokoll vom $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')")
$protokoll.Add("Computer: $env:COMPUTERNAME   Benutzer: $env:USERNAME")
$protokoll.Add("Windows:  $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption) / Build $([System.Environment]::OSVersion.Version)")
$protokoll.Add("PowerShell: $($PSVersionTable.PSVersion)  ($(if ([Environment]::Is64BitProcess) { '64-Bit' } else { '32-BIT!' }))")
$protokoll.Add("")

$protokoll.Add("--- FEHLER ($($script:Fehlerliste.Count)) ---")
if ($script:Fehlerliste.Count -gt 0) { foreach ($f in $script:Fehlerliste) { $protokoll.Add("  $f") } }
else { $protokoll.Add("  keine") }
$protokoll.Add("")

$protokoll.Add("--- NOCH ZU ERLEDIGEN ($($script:Hinweisliste.Count)) ---")
if ($script:Hinweisliste.Count -gt 0) { foreach ($h in $script:Hinweisliste) { $protokoll.Add("  $h") } }
else { $protokoll.Add("  keine") }
$protokoll.Add("")

$protokoll.Add("--- DIAGNOSE ($($script:Diagnoseliste.Count)) ---")
if ($script:Diagnoseliste.Count -gt 0) { foreach ($d in $script:Diagnoseliste) { $protokoll.Add("  $d") } }
else { $protokoll.Add("  keine") }

# Ueber die Shell-Funktion, damit ein per OneDrive umgeleiteter Desktop stimmt.
$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
$protokollDatei = Join-Path $desktop "AutoEinrichtung_Protokoll.txt"

try {
    Set-Content -Path $protokollDatei -Value $protokoll -Encoding UTF8 -Force -ErrorAction Stop
    Write-Host ""
    Write-Success "Protokoll gespeichert unter: $protokollDatei"
} catch {
    Write-Warn "Protokoll konnte nicht gespeichert werden: $($_.Exception.Message)"
}

Write-Host ""
Write-Linie '=' 'DarkGray'
Read-Host "  Druecke Enter um das Skript zu beenden..."
