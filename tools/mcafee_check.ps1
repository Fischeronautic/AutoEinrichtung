$m = 'McAfee'
Write-Host "`n=== 1) Klassische Programme (Uninstall-Schluessel) ===" -ForegroundColor Cyan
$pfade = @(
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$treffer = @(Get-ItemProperty $pfade -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -and $_.DisplayName -like "*$m*" })
if ($treffer.Count -eq 0) { Write-Host "  KEINE gefunden" -ForegroundColor Yellow }
foreach ($t in $treffer) {
  Write-Host "  DisplayName          : $($t.DisplayName)"
  Write-Host "  UninstallString      : $($t.UninstallString)"
  Write-Host "  QuietUninstallString : $($t.QuietUninstallString)"
  Write-Host "  Publisher / Version  : $($t.Publisher) / $($t.DisplayVersion)"
  Write-Host ""
}

Write-Host "=== 2) Store-Apps ===" -ForegroundColor Cyan
$a = @(Get-AppxPackage -AllUsers -Name "*$m*" -ErrorAction SilentlyContinue)
if ($a.Count -eq 0) { Write-Host "  KEINE gefunden" -ForegroundColor Yellow }
$a | ForEach-Object { Write-Host "  $($_.Name)  |  $($_.PackageFullName)" }

Write-Host "`n=== 3) Provisionierte Apps (Image) ===" -ForegroundColor Cyan
$p = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*$m*" })
if ($p.Count -eq 0) { Write-Host "  KEINE gefunden" -ForegroundColor Yellow }
$p | ForEach-Object { Write-Host "  $($_.DisplayName)  |  $($_.PackageName)" }

Write-Host "`n=== 4) Was die Systemsteuerung sonst noch kennt ===" -ForegroundColor Cyan
Get-ItemProperty $pfade -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName } |
  Select-Object -ExpandProperty DisplayName |
  Sort-Object -Unique
