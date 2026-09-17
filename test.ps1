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
# 0. UI-Hilfsfunktionen & Ergebnis-Sammlung
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
# Sammelt offene Punkte. Aktuell nur Ablage: jeder Hinweis wird an seiner
# Fundstelle bereits ausgegeben, eine Zusammenfassung am Ende gibt es nicht mehr.
function Add-Hinweis  { param([string]$Message) $script:Hinweisliste.Add($Message) }
function Add-Diagnose {
    param([string]$Message)
    $script:Diagnoseliste.Add($Message)
    Write-Host "[d] $Message" -ForegroundColor DarkGray
}

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

# Zerlegt einen Deinstallationsbefehl in Programm und Argumente.
# Der Umweg ueber cmd.exe scheitert, wenn der Befehl Leerzeichen im Pfad hat,
# aber keine eigenen Anfuehrungszeichen - cmd versucht dann 'C:\Program' zu
# starten und beendet sich sofort, ohne dass ein Fenster stehen bleibt.
function Split-Deinstallationsbefehl {
    param([string]$Befehl)

    $Befehl = $Befehl.Trim()

    if ($Befehl.StartsWith('"')) {
        $ende = $Befehl.IndexOf('"', 1)
        if ($ende -gt 1) {
            return [pscustomobject]@{
                Datei     = $Befehl.Substring(1, $ende - 1)
                Argumente = $Befehl.Substring($ende + 1).Trim()
            }
        }
    }

    $treffer = [regex]::Match($Befehl, '^(?<exe>.+?\.exe)\s*(?<rest>.*)$', 'IgnoreCase')
    if ($treffer.Success) {
        return [pscustomobject]@{
            Datei     = $treffer.Groups['exe'].Value.Trim()
            Argumente = $treffer.Groups['rest'].Value.Trim()
        }
    }

    return [pscustomobject]@{ Datei = $Befehl; Argumente = '' }
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

# Architektur feststellen. Auf ARM-Geraeten verhalten sich mehrere Installer
# anders - das gleich zu wissen erspart Fehlersuche.
$script:Architektur = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$script:IstArm64    = ($script:Architektur -eq 'ARM64')
if ($script:IstArm64) {
    Write-Warn "Prozessorarchitektur: $($script:Architektur) - einzelne Programme verweigern auf ARM die Installation."
} else {
    Write-Info "Prozessorarchitektur: $($script:Architektur)"
}

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
    '10' = @{ Name = "Outlook klassisch (Microsoft 365)"; Custom = "Outlook" }
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

    Write-Info "Deaktiviere Autostart-Eintraege..."

    # Deaktiviert wird ueber StartupApproved - genau die Stelle, die auch der
    # Task-Manager benutzt. Nichts wird geloescht, alles bleibt im
    # Task-Manager unter 'Autostart' mit einem Klick reaktivierbar.
    $disabledValue = [byte[]](0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
    $deaktiviert   = New-Object System.Collections.Generic.List[string]

    # --- Klassische Run-Schluessel ---
    $runPaare = @(
        @{ Run = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
           Ok  = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
           Ebene = "Benutzer" },
        @{ Run = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
           Ok  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
           Ebene = "System" }
    )

    foreach ($paar in $runPaare) {
        if (-not (Test-Path $paar.Run)) { continue }
        $eintraege = @(Get-ItemProperty -Path $paar.Run -ErrorAction SilentlyContinue |
                       Get-Member -MemberType NoteProperty |
                       Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' })
        foreach ($eintrag in $eintraege) {
            if (Set-RegValue -Path $paar.Ok -Name $eintrag.Name -Value $disabledValue -Type 'Binary' -Leise) {
                $deaktiviert.Add("$($eintrag.Name)  [$($paar.Ebene)]")
            } else {
                Write-Warn "Autostart '$($eintrag.Name)' konnte nicht deaktiviert werden."
            }
        }
    }

    # --- Verknuepfungen im Autostart-Ordner ---
    $ordnerPaare = @(
        @{ Ordner = [Environment]::GetFolderPath('Startup')
           Ok = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
           Ebene = "Autostart-Ordner" },
        @{ Ordner = [Environment]::GetFolderPath('CommonStartup')
           Ok = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
           Ebene = "Autostart-Ordner (alle)" }
    )

    foreach ($paar in $ordnerPaare) {
        if ([string]::IsNullOrWhiteSpace($paar.Ordner) -or -not (Test-Path $paar.Ordner)) { continue }
        $dateien = @(Get-ChildItem -Path $paar.Ordner -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ne 'desktop.ini' })
        foreach ($datei in $dateien) {
            if (Set-RegValue -Path $paar.Ok -Name $datei.Name -Value $disabledValue -Type 'Binary' -Leise) {
                $deaktiviert.Add("$($datei.BaseName)  [$($paar.Ebene)]")
            }
        }
    }

    # --- Store-Apps (Phone Link, Teams, Cortana ...) ---
    # Diese tauchen in den Einstellungen unter Autostart auf, liegen aber
    # nicht in den Run-Schluesseln, sondern als StartupTask je App-Paket.
    $appModelPfad = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
    if (Test-Path $appModelPfad) {
        foreach ($paket in @(Get-ChildItem -Path $appModelPfad -ErrorAction SilentlyContinue)) {
            foreach ($task in @(Get-ChildItem -Path $paket.PSPath -ErrorAction SilentlyContinue)) {

                $werte = Get-ItemProperty -Path $task.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $werte -or $null -eq $werte.State) { continue }

                $paketName = $paket.PSChildName -replace '_.*$', ''

                try {
                    $art = (Get-Item -Path $task.PSPath).GetValueKind('State')
                } catch {
                    continue
                }

                # Nur den DWord-Fall anfassen. Der alte Wert wandert in die
                # Diagnose, damit die Bedeutung der Zahlen belegbar ist statt geraten.
                if ($art -ne 'DWord') {
                    Add-Diagnose "StartupTask '$paketName\$($task.PSChildName)': State ist $art (nicht angefasst)."
                    continue
                }

                $altWert = [int]$werte.State
                if ($altWert -eq 1) { continue }   # gilt als bereits deaktiviert

                if (Set-RegValue -Path $task.PSPath -Name 'State' -Value 1 -Type 'DWord' -Leise) {
                    $deaktiviert.Add("$paketName  [Store-App]")
                    Add-Diagnose "StartupTask '$paketName\$($task.PSChildName)': State $altWert -> 1"
                } else {
                    Write-Warn "Autostart der Store-App '$paketName' konnte nicht deaktiviert werden."
                }
            }
        }
    }

    if ($deaktiviert.Count -gt 0) {
        Write-Success "$($deaktiviert.Count) Autostart-Eintraege deaktiviert:"
        foreach ($eintrag in $deaktiviert) { Write-Host "      - $eintrag" -ForegroundColor DarkGray }
        Add-Hinweis "Autostart: $($deaktiviert.Count) Eintraege deaktiviert - im Task-Manager unter 'Autostart' einzeln wieder aktivierbar."
    } else {
        Write-Info "Keine aktiven Autostart-Eintraege gefunden."
    }
}

# ==========================================
# 5. Bloatware-Bereinigung (Muellschlucker)
# ==========================================
if ($systemSetup) {
    Write-Schritt "Bloatware-Bereinigung"
    Write-Info "Starte Bloatware-Bereinigung (Suche nach Junk-Apps)..."
    $bloatwareList = @("McAfee", "WebAdvisor", "Norton", "ExpressVPN", "Dropbox", "TikTok", "Instagram", "Facebook", "Spotify", "WhatsApp")
    $gefundeneProgramme = 0

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

        # --- Provisionierte Apps ZUERST (fuer kuenftige Benutzerkonten) ---
        # Reihenfolge ist wichtig: sind die Paketdateien durch Remove-AppxPackage
        # schon weg, scheitert das Entfernen aus dem Image mit 'Datei nicht gefunden'.
        foreach ($prov in ($provisioned | Where-Object { $_.DisplayName -like "*$junk*" })) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                Write-Success "$($prov.DisplayName) aus dem Windows-Image entfernt (kommt bei neuen Konten nicht wieder)."
            } catch {
                # 0x80070002 / 0x80070003: Datei bzw. Pfad nicht gefunden. Dann ist
                # im Image ohnehin nichts mehr da - das ist kein Fehlschlag.
                $hResult = $_.Exception.HResult
                if ($hResult -eq -2147024894 -or $hResult -eq -2147024893) {
                    Write-Info "$($prov.DisplayName) war im Windows-Image bereits nicht mehr vorhanden."
                } else {
                    Write-ErrorMsg "$($prov.DisplayName) konnte nicht aus dem Image entfernt werden: $($_.Exception.Message)"
                }
            }
        }

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

        # --- Klassische Desktop-Programme ---
        $desktopApps = @(Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
                         Where-Object { $_.DisplayName -and $_.DisplayName -like "*$junk*" })

        if ($desktopApps.Count -gt 0) {
            Write-Info "Programm gefunden zu '$junk': $(($desktopApps.DisplayName | Select-Object -Unique) -join ', ')"
        }

        foreach ($app in $desktopApps) {
            $gefundeneProgramme++

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
                    $teile = Split-Deinstallationsbefehl $app.UninstallString
                    Add-Diagnose "Deinstallation starten: Datei='$($teile.Datei)' Argumente='$($teile.Argumente)'"

                    if ($teile.Argumente) {
                        $prozess = Start-Process -FilePath $teile.Datei -ArgumentList $teile.Argumente -PassThru -ErrorAction Stop
                    } else {
                        $prozess = Start-Process -FilePath $teile.Datei -PassThru -ErrorAction Stop
                    }

                    # Ein stiller Schalter existiert fuer diese Deinstaller nicht:
                    # mc-update.exe /uninstall /silent oeffnet trotzdem ein Fenster
                    # und bleibt bei 0 Prozent stehen. Deshalb gleich der normale Weg.
                    # Kurz nachsehen, ob wirklich etwas stehen bleibt - beendet sich
                    # der Aufruf sofort, kam auch kein Fenster.
                    Start-Sleep -Seconds 3
                    if ($prozess.HasExited) {
                        Write-ErrorMsg "$($app.DisplayName): Deinstaller hat sich sofort beendet (Exitcode $($prozess.ExitCode)) - es kam kein Fenster."
                        Add-Hinweis "$($app.DisplayName) ueber 'Apps & Features' von Hand deinstallieren."
                    } else {
                        $script:AsyncJobs.Add([pscustomobject]@{ Name = $app.DisplayName; Prozess = $prozess })
                        Add-Hinweis "$($app.DisplayName): Deinstallationsfenster wurde geoeffnet - bitte durchklicken."
                    }
                } catch {
                    Write-ErrorMsg "$($app.DisplayName): Deinstallation konnte nicht gestartet werden: $($_.Exception.Message)"
                    Add-Hinweis "$($app.DisplayName) manuell deinstallieren."
                }
            }
        }
    }
    if ($gefundeneProgramme -eq 0) {
        Write-Success "Bloatware-Pruefung abgeschlossen - keine klassischen Programme gefunden."
        Write-Info "Falls trotzdem etwas in 'Apps & Features' steht, sag mir den genauen Namen."
    } else {
        Write-Success "Bloatware-Pruefung abgeschlossen - $gefundeneProgramme Programm(e) behandelt."
    }
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
function Test-OutlookVorhanden {
    $pfade = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\OUTLOOK.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\OUTLOOK.EXE')
    )
    foreach ($pfad in $pfade) {
        if ($pfad -and (Test-Path $pfad)) { return $true }
    }
    foreach ($schluessel in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE",
                              "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE")) {
        if (Test-Path $schluessel) { return $true }
    }
    # Falls Office an einem ungewoehnlichen Ort liegt: im Office-Ordner suchen.
    foreach ($wurzel in @((Join-Path $env:ProgramFiles 'Microsoft Office'),
                          (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office'))) {
        if ($wurzel -and (Test-Path $wurzel)) {
            $treffer = Get-ChildItem -Path $wurzel -Filter 'OUTLOOK.EXE' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                       Select-Object -First 1
            if ($treffer) { return $true }
        }
    }
    return $false
}

# Installiert Microsoft 365 inklusive Outlook ueber das Office Deployment Tool.
# Ist bereits eine Click-to-Run-Installation vorhanden, werden deren Produkt,
# Sprache und Plattform uebernommen - ODT ergaenzt sie dann, statt eine zweite
# danebenzustellen. Fehlt sie, wird mit Standardwerten frisch installiert.
#
# WICHTIG: --override ERSETZT die Installer-Argumente. Nur '/configure <xml>'
# ist hier gueltig - ein 'Language=de-de' allein bewirkt nichts.
function Install-Outlook {

    if (Test-OutlookVorhanden) {
        Write-Success "Outlook ist bereits installiert."
        return
    }

    $produkt   = 'O365HomePremRetail'
    $sprache   = 'de-de'
    $plattform = '64'

    $c2rPfad = @(
        "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($c2rPfad) {
        $cfg = Get-ItemProperty -Path $c2rPfad -ErrorAction SilentlyContinue
        if ($cfg.ProductReleaseIds) {
            # OneNote, Visio und Project sind Beiprodukte - gesucht ist das
            # eigentliche Office. Auf Werksgeraeten steht z.B.
            # 'OneNoteFreeRetail,O365HomePremRetail' im Schluessel.
            $kandidaten = @($cfg.ProductReleaseIds -split ',' |
                            ForEach-Object { $_.Trim() } |
                            Where-Object { $_ -and $_ -notmatch '(?i)visio|project|onenote' })
            $vorhanden = $kandidaten | Where-Object { $_ -match '(?i)o365|office|microsoft365' } | Select-Object -First 1
            if (-not $vorhanden) { $vorhanden = $kandidaten | Select-Object -First 1 }
            if ($vorhanden) { $produkt = $vorhanden }
        }
        if ($cfg.ClientCulture) { $sprache = $cfg.ClientCulture }
        if ($cfg.Platform -eq 'x86') { $plattform = '32' }
        Write-Info "Vorhandene Office-Installation erkannt: $produkt / $sprache / ${plattform}-Bit"
    } else {
        Write-Info "Keine Click-to-Run-Installation gefunden - Neuinstallation mit $produkt / $sprache / ${plattform}-Bit"
    }

    # Eigener Protokollordner - das Setup schreibt dort mit, was es tut.
    $logOrdner = Join-Path $env:SystemRoot "Temp\AutoEinrichtungOffice"
    Remove-Item -Path $logOrdner -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $logOrdner -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    # Bewusst OHNE ExcludeApp: ein Ausschluss wuerde bereits vorhandene
    # Programme wie Word oder Excel aus der Installation ENTFERNEN.
    $officeXml = @"
<Configuration>
  <Add OfficeClientEdition="$plattform">
    <Product ID="$produkt">
      <Language ID="$sprache" />
    </Product>
  </Add>
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Logging Level="Standard" Path="$logOrdner" />
</Configuration>
"@

    # Pfade OHNE Leerzeichen - erspart Anfuehrungszeichen-Aerger.
    $xmlPfad = Join-Path $logOrdner "configuration.xml"
    try {
        # ASCII statt UTF8: Windows PowerShell schreibt bei UTF8 eine
        # Bytefolgemarke an den Dateianfang. Der Inhalt ist reines ASCII,
        # damit ist die Datei garantiert ohne Vorspann.
        Set-Content -Path $xmlPfad -Value $officeXml -Encoding ASCII -Force -ErrorAction Stop
    } catch {
        Write-ErrorMsg "Office-Konfiguration konnte nicht geschrieben werden: $($_.Exception.Message)"
        return
    }

    $null = Wait-InstallerFrei -MaxSekunden 900

    # Setup direkt von Microsoft holen statt ueber das winget-Paket.
    # Microsoft aktualisiert diese setup.exe oefter als das winget-Manifest
    # gepflegt wird, dadurch scheitert 'winget install Microsoft.Office'
    # regelmaessig mit 0x8A150011 (Hash stimmt nicht). Dieselbe Datei,
    # dieselbe Quelle, nur ohne das veraltete Manifest dazwischen.
    $setupPfad = Join-Path $logOrdner "setup.exe"
    $ausgabe   = @()
    $code      = $null

    Write-Info "Lade Office-Setup von Microsoft..."
    try {
        Invoke-WebRequest -Uri "https://officecdn.microsoft.com/pr/wsus/setup.exe" `
                          -OutFile $setupPfad -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warn "Download fehlgeschlagen ($($_.Exception.Message)) - versuche es ueber winget."
        $setupPfad = $null
    }

    # Datei pruefen, bevor sie gestartet wird. Eine leere oder falsche Datei
    # startet klaglos und tut nichts - genau das war bisher nicht erkennbar.
    if ($setupPfad) {
        $datei = Get-Item -Path $setupPfad -ErrorAction SilentlyContinue
        if (-not $datei) {
            Write-Warn "Heruntergeladene Datei nicht auffindbar - versuche es ueber winget."
            $setupPfad = $null
        } else {
            $kopf = ''
            try {
                $rohbytes = [System.IO.File]::ReadAllBytes($setupPfad)[0..1]
                $kopf = -join ($rohbytes | ForEach-Object { [char]$_ })
            } catch { }

            Add-Diagnose "Office-Setup geladen: $([math]::Round($datei.Length / 1MB, 2)) MB, Dateikopf '$kopf'"

            if ($datei.Length -lt 500KB -or $kopf -ne 'MZ') {
                Write-ErrorMsg "Die heruntergeladene Datei ist kein lauffaehiges Setup ($([math]::Round($datei.Length / 1KB)) KB, Kopf '$kopf')."
                $setupPfad = $null
            } else {
                Write-Success "Setup geladen ($([math]::Round($datei.Length / 1MB, 2)) MB)."
            }
        }
    }

    Write-Info "Office Deployment Tool laeuft - das dauert einige Minuten (Download)."
    try {
        if ($setupPfad) {
            # /configure ist der vorgesehene Schalter des Deployment Tools.
            # Was dabei passiert, steht im Protokollordner.
            # Arbeitsverzeichnis auf den Ordner setzen, in dem setup.exe und
            # configuration.xml liegen. Aus C:\Windows\system32 heraus gestartet
            # beendete sich das Setup wortlos mit 0 - so laeuft es auch von Hand.
            $ausgabeDatei = Join-Path $logOrdner "setup_ausgabe.txt"
            $fehlerDatei  = Join-Path $logOrdner "setup_fehler.txt"
            $prozess = Start-Process -FilePath $setupPfad -ArgumentList '/configure', 'configuration.xml' `
                          -WorkingDirectory $logOrdner -PassThru -Wait -ErrorAction Stop `
                          -RedirectStandardOutput $ausgabeDatei -RedirectStandardError $fehlerDatei
            $code = $prozess.ExitCode
            foreach ($datei in @($ausgabeDatei, $fehlerDatei)) {
                if (Test-Path $datei) {
                    $inhalt = @(Get-Content -Path $datei -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
                    foreach ($zeile in ($inhalt | Select-Object -Last 5)) { Add-Diagnose "Setup sagt: $($zeile.Trim())" }
                }
            }
        } else {
            $ausgabe = & winget.exe install --id Microsoft.Office -e --source winget `
                          --accept-package-agreements --accept-source-agreements `
                          --override "/configure $xmlPfad" 2>&1
            $code = $LASTEXITCODE
        }
    } catch {
        Write-ErrorMsg "Outlook: Installation konnte nicht gestartet werden: $($_.Exception.Message)"
        Remove-Item -Path $xmlPfad -Force -ErrorAction SilentlyContinue
        return
    }


    # Entscheidend ist nicht der Exitcode, sondern ob Outlook danach da ist.
    if (Test-OutlookVorhanden) {
        Write-Success "Outlook ist installiert (Sprache: $sprache)."
        Add-Hinweis "Outlook: beim ersten Start meldet sich der Kunde mit seinem Microsoft-Konto an."
    } else {
        Write-ErrorMsg "Outlook wurde NICHT installiert (Exitcode $code)."
        $letzteZeilen = @($ausgabe | Where-Object { $_ -and "$_".Trim() } | Select-Object -Last 5)
        if ($letzteZeilen.Count -gt 0) { Write-Warn "    Ausgabe: $(($letzteZeilen -join ' | ').Trim())" }

        # Zeigen, was wirklich vorliegt - bei Exitcode 0 ohne Ergebnis ist das
        # der einzige Weg herauszufinden, was das Setup gemacht hat.
        foreach ($wurzel in @((Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16'),
                              (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16'))) {
            if ($wurzel -and (Test-Path $wurzel)) {
                $exen = @(Get-ChildItem -Path $wurzel -Filter '*.EXE' -ErrorAction SilentlyContinue |
                          Select-Object -ExpandProperty Name)
                Add-Diagnose "Office-Ordner '$wurzel': $(if ($exen.Count) { $exen -join ', ' } else { 'leer' })"
            } else {
                Add-Diagnose "Office-Ordner '$wurzel' existiert nicht."
            }
        }
        # Die Ausschlussliste der vorhandenen Installation zeigen. Bei
        # vorinstalliertem Microsoft 365 ist Outlook dort oft eingetragen,
        # und genau das laesst /configure unangetastet.
        if ($c2rPfad) {
            $alleWerte = Get-ItemProperty -Path $c2rPfad -ErrorAction SilentlyContinue
            foreach ($name in @($alleWerte.PSObject.Properties.Name |
                                Where-Object { $_ -match '(?i)excluded|productrelease|clientculture|platform|updatechannel|versiontoreport' })) {
                Add-Diagnose "C2R $name = $($alleWerte.$name)"
            }
        }

        # Protokoll des Setups direkt anzeigen - da steht der eigentliche Grund.
        $log = Get-ChildItem -Path $logOrdner -Filter '*.log' -Recurse -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            Add-Diagnose "Setup-Protokoll: $($log.FullName)"
            $zeilen = @(Get-Content -Path $log.FullName -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match '(?i)error|fail|abort|denied|invalid|not found' } |
                        Select-Object -Last 8)
            if ($zeilen.Count -eq 0) {
                $zeilen = @(Get-Content -Path $log.FullName -ErrorAction SilentlyContinue | Select-Object -Last 8)
            }
            foreach ($zeile in $zeilen) { Add-Diagnose "   $($zeile.Trim())" }
        } else {
            $inhalt = @(Get-ChildItem -Path $logOrdner -Recurse -File -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Name)
            Add-Diagnose "Kein Setup-Protokoll. Inhalt von '$logOrdner': $(if ($inhalt.Count) { $inhalt -join ', ' } else { 'leer' })"
        }

        Add-Hinweis "Outlook manuell nachinstallieren."
    }
}

if ($selectedApps.Count -gt 0) {
    Write-Schritt "App-Installation"
    Write-Info "Wird installiert: $((($selectedApps | ForEach-Object { $wingetApps[$_].Name })) -join ', ')"

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
        } elseif ($script:IstArm64 -and $app.Id -like 'Adobe.Acrobat.Reader*') {
            # Belegt durch das Installationsprotokoll: das mitgelieferte
            # Update-Paket bricht mit 'ARM64 architecture detected - patch will
            # be blocked' ab, danach macht MSI alles rueckgaengig (Fehler 1603).
            # Drei Fehlversuche bringen daran nichts.
            Write-Warn "$($app.Name) laesst sich auf ARM-Geraeten nicht installieren."
            Write-Info "    Adobe bietet keine ARM-Fassung; das Update-Paket im winget-Paket blockiert die Architektur."

            # Sumatra PDF hat seit 3.5.2 einen eigenen ARM64-Build und laeuft
            # dort nativ - damit hat der Kunde trotzdem einen PDF-Betrachter.
            if ($selectedApps -contains '8') {
                Write-Info "    Sumatra PDF ist ohnehin ausgewaehlt und wird als PDF-Betrachter installiert."
            } else {
                Write-Info "    Stattdessen wird Sumatra PDF installiert - das laeuft nativ auf ARM."
                Install-WingetApp -Id $wingetApps['8'].Id -Name $wingetApps['8'].Name
            }
            Add-Hinweis "$($app.Name): auf ARM-Geraet nicht moeglich - Sumatra PDF wurde stattdessen eingerichtet."
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
# 9. Zusammenfassung
# ==========================================
# ==========================================
# 8b. Windows-Standard-Apps (Browser / PDF)
# ==========================================
# Setzen laesst sich das nicht: seit dem UserChoice Protection Driver (UCPD)
# sind die UserChoice-Schluessel fuer http, https und .pdf hash-geschuetzt.
# Das ist derselbe Schutz, der auch TaskbarDa blockiert - Werkzeuge wie
# SetUserFTA funktionieren deshalb ebenfalls nicht mehr. UCPD abzuschalten
# kommt nicht in Frage, der Treiber verhindert genau dieses Kapern.
# Also: Einstellungsseite oeffnen, damit es zwei Klicks statt Sucherei sind.
if ($systemSetup -and $selectedApps.Count -gt 0) {

    $standardRelevant = @{
        '2' = 'Google Chrome (Standardbrowser)'
        '4' = 'Firefox (Standardbrowser)'
        '3' = 'Adobe Acrobat Reader (PDF)'
        '8' = 'Sumatra PDF (PDF)'
        '9' = 'Foxit PDF Reader (PDF)'
    }

    $kandidaten = @($selectedApps |
                    Where-Object { $standardRelevant.ContainsKey($_) } |
                    ForEach-Object { $standardRelevant[$_] })

    if ($kandidaten.Count -gt 0) {
        Write-Host ""
        Write-Info "Standard-Apps kann Windows aus Schutzgruenden nicht per Skript setzen."
        Write-Info "Bitte von Hand festlegen: $($kandidaten -join ', ')"
        try {
            Start-Process "ms-settings:defaultapps" -ErrorAction Stop
            Write-Success "Die Einstellungsseite 'Standard-Apps' wurde dafuer geoeffnet."
        } catch {
            Write-Warn "Einstellungsseite konnte nicht geoeffnet werden: $($_.Exception.Message)"
        }
        Add-Hinweis "Standard-Apps von Hand setzen: $($kandidaten -join ', ')."
    }
}

Stop-Fortschritt

$abschlussFarbe = if ($script:Fehlerliste.Count -gt 0) { 'Yellow' } else { 'Green' }
$abschlussText  = if ($script:Fehlerliste.Count -gt 0) {
    "Ersteinrichtung beendet - $($script:Fehlerliste.Count) Punkt(e) haben nicht geklappt"
} else {
    "Ersteinrichtung erfolgreich abgeschlossen"
}
Write-Banner $abschlussText "" $abschlussFarbe

# Haelt das Fenster offen, wenn das Skript per Doppelklick gestartet wurde.
Write-Host ""
Read-Host "  Druecke Enter um das Skript zu beenden..."
