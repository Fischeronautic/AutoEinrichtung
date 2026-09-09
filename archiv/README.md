# Archiv

Eingefrorene Staende von `test.ps1`. Die Dateien hier werden nicht mehr
geaendert - sie dienen als Rueckfallebene, falls die aktuelle Version im
Repository-Hauptverzeichnis Probleme macht.

| Datei | Stand | Commit |
|---|---|---|
| `test_v1_original.ps1` | Vor der Ueberarbeitung, bis September 2026 produktiv | `0ed5559` |
| `test_v2_ueberarbeitet.ps1` | Ueberarbeitung September 2026 | `c835841` |

## Rueckfall auf die alte Fassung

In einer als Administrator gestarteten PowerShell:

```powershell
irm https://raw.githubusercontent.com/Fischeronautic/AutoEinrichtung/main/archiv/test_v1_original.ps1 | iex
```

Die aktuelle, gepflegte Fassung liegt unveraendert unter `test.ps1` im
Hauptverzeichnis und wird ueber die gewohnte URL aufgerufen.

## Was sich in v2 geaendert hat

- Fehlerbehandlung: `try/catch` in Kombination mit `-ErrorAction SilentlyContinue`
  aufgeloest, dadurch keine falschen Erfolgsmeldungen mehr
- Winget-Exitcodes korrigiert (`-1978335215` ist ein Hash-Fehler, kein Erfolg),
  dazu Wiederholversuche, Warten auf den MSI-Mutex und Pruefung per `winget list`
- Firefox und Thunderbird auf die deutschen Pakete umgestellt
- Outlook laesst sich in eine vorhandene Microsoft-365-Installation nachtragen
- Taskleiste ueber `LayoutModification.xml` statt der wirkungslosen JSON-Variante
- Autostart vollstaendig ueber `StartupApproved` deaktiviert, per Task-Manager
  wieder aktivierbar
- Bloatware ohne stille Deinstallation blockiert das Skript nicht mehr
- App-Auswahl per Klickliste, Schrittzaehler und Fortschrittsbalken
