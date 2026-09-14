Write-Host "`n=== 1) Click-to-Run Konfiguration ===" -ForegroundColor Cyan
$c2r = @(
  "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration"
)
$gefunden = $false
foreach ($p in $c2r) {
  if (Test-Path $p) {
    $gefunden = $true
    Write-Host "  GEFUNDEN: $p" -ForegroundColor Green
    $v = Get-ItemProperty $p
    foreach ($n in 'ProductReleaseIds','ClientCulture','Platform','VersionToReport','UpdateChannel','AudienceData') {
      Write-Host ("    {0,-18}= {1}" -f $n, $v.$n)
    }
  }
}
if (-not $gefunden) { Write-Host "  KEINE Click-to-Run-Konfiguration vorhanden" -ForegroundColor Yellow }

Write-Host "`n=== 2) Gibt es den ClickToRun-Zweig ueberhaupt? ===" -ForegroundColor Cyan
foreach ($p in @("HKLM:\SOFTWARE\Microsoft\Office\ClickToRun","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun")) {
  if (Test-Path $p) { Write-Host "  vorhanden: $p  -> Unterschluessel: $((Get-ChildItem $p -EA SilentlyContinue).PSChildName -join ', ')" -ForegroundColor Green }
  else { Write-Host "  fehlt: $p" -ForegroundColor Yellow }
}

Write-Host "`n=== 3) Programme mit Office-Bezug (Uninstall-Schluessel) ===" -ForegroundColor Cyan
$pfade = @(
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$t = @(Get-ItemProperty $pfade -EA SilentlyContinue |
       Where-Object { $_.DisplayName -match '(?i)office|microsoft 365|word|excel|powerpoint|outlook' })
if ($t.Count -eq 0) { Write-Host "  KEINE gefunden" -ForegroundColor Yellow }
$t | ForEach-Object { Write-Host "  $($_.DisplayName)   [$($_.DisplayVersion)]" }

Write-Host "`n=== 4) Store-Apps mit Office-Bezug ===" -ForegroundColor Cyan
$a = @(Get-AppxPackage -AllUsers -EA SilentlyContinue |
       Where-Object { $_.Name -match '(?i)office|word|excel|powerpoint|outlook|onenote' })
if ($a.Count -eq 0) { Write-Host "  KEINE gefunden" -ForegroundColor Yellow }
$a | ForEach-Object { Write-Host "  $($_.Name)   ($($_.Version))" }

Write-Host "`n=== 5) Wo liegt Word wirklich? ===" -ForegroundColor Cyan
$gefundenExe = $false
foreach ($k in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\winword.exe",
                 "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\winword.exe")) {
  if (Test-Path $k) { Write-Host "  $((Get-ItemProperty $k).'(default)')" -ForegroundColor Green; $gefundenExe = $true }
}
foreach ($d in @("$env:ProgramFiles\Microsoft Office\root\Office16",
                 "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16")) {
  if (Test-Path (Join-Path $d 'WINWORD.EXE')) { Write-Host "  $d\WINWORD.EXE" -ForegroundColor Green; $gefundenExe = $true }
}
if (-not $gefundenExe) { Write-Host "  Keine klassische WINWORD.EXE gefunden -> Word ist vermutlich die Store-Variante" -ForegroundColor Yellow }
