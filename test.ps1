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
    # Hier ist der neue Bremsklotz:
    Read-Host "Druecke Enter, um dieses Fenster zu schliessen..."
    exit
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
