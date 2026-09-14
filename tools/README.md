# Diagnosewerkzeuge

Reine Lesewerkzeuge zur Fehlersuche. Sie veraendern nichts am System und
sind nicht Teil der Ersteinrichtung.

Aufruf in einer als Administrator gestarteten PowerShell:

```powershell
# Was fuer eine Office-Installation liegt auf dem Geraet?
irm https://raw.githubusercontent.com/Fischeronautic/AutoEinrichtung/main/tools/office_check.ps1 | iex

# Welche McAfee-Reste sind vorhanden und wie lassen sie sich deinstallieren?
irm https://raw.githubusercontent.com/Fischeronautic/AutoEinrichtung/main/tools/mcafee_check.ps1 | iex
```
