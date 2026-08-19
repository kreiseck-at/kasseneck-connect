; Inno-Setup-Skript für Kasseneck Connect (Windows).
;
;   ISCC.exe /DAppVersion=0.1.0 tool\installer\windows\KasseneckConnect.iss
;   -> build\KasseneckConnect-<version>-windows-x64.exe
;
; Installiert ohne Administratorrechte nach %LocalAppData%\KasseneckConnect,
; richtet danach den Autostart über die Aufgabenplanung ein und startet den
; Agenten. Das Paket ist **unsigniert** (v1.0) — SmartScreen meldet sich beim
; ersten Start; die Anleitung dazu steht in der README.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Kasseneck Connect"
#define AppExe "kasseneck-connect.exe"
#define AppPublisher "Kreiseck – Software Solutions"

[Setup]
AppId={{9C6E5F1A-2B4D-4F0E-9C21-7E5A3D8B14C7}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://kasseneck.at
DefaultDirName={localappdata}\KasseneckConnect
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Ohne Administratorrechte: der Agent gehört zur angemeldeten Kassenkraft.
PrivilegesRequired=lowest
; `x64` statt `x64compatible`: das versteht auch Inno Setup 6.0. Neuere
; Fassungen halten es für veraltet, bauen damit aber weiterhin.
ArchitecturesInstallIn64BitMode=x64
OutputDir=..\..\..\build
; Der Name muss zur Regel in tool/_common.sh passen — er wird beim Release zu
; KasseneckConnect-windows-x64.exe unter connect/latest/.
OutputBaseFilename=KasseneckConnect-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Files]
Source: "..\..\..\build\kasseneck-connect-windows-x64.exe"; DestDir: "{app}"; DestName: "{#AppExe}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName} — Kopplungscode"; Filename: "{app}\{#AppExe}"; Parameters: "pair"
Name: "{group}\{#AppName} — Diagnose"; Filename: "{app}\{#AppExe}"; Parameters: "doctor"

[Run]
; Erst der Autostart-Eintrag (Aufgabenplanung, „Bei Anmeldung"), er startet den
; Agenten gleich mit; danach der Kopplungscode für die Kasse.
Filename: "{app}\{#AppExe}"; Parameters: "install-autostart"; StatusMsg: "Autostart wird eingerichtet …"; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExe}"; Parameters: "pair"; Description: "Kasse jetzt koppeln"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; Vor dem Löschen der Dateien: Aufgabe entfernen und Agenten anhalten.
Filename: "{app}\{#AppExe}"; Parameters: "uninstall-autostart"; RunOnceId: "UninstallAutostart"; Flags: runhidden waituntilterminated

[Code]
// Beim Update läuft der alte Agent noch und hält seine eigene .exe offen —
// [Files] käme dann an der gesperrten Datei nicht vorbei. `PrepareToInstall`
// ist der einzige Haken, der **vor** dem Kopieren greift: er nimmt den
// Autostart-Eintrag heraus und hält den laufenden Agenten an.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExistingExe: String;
  ResultCode: Integer;
begin
  Result := '';
  NeedsRestart := False;
  ExistingExe := ExpandConstant('{app}\{#AppExe}');

  if FileExists(ExistingExe) then
  begin
    // Erst hart beenden: `uninstall-autostart` nimmt die Aufgabe aus der
    // Aufgabenplanung und hält den von ihr gestarteten Agenten an — einen von
    // Hand gestarteten oder einen hängenden Prozess erwischt es nicht, und
    // genau der hält weiter seine .exe gesperrt. taskkill räumt beide ab.
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExe} /F', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    Exec(ExistingExe, 'uninstall-autostart', '', SW_HIDE,
      ewWaitUntilTerminated, ResultCode);
    // Fehlschläge beider Aufrufe sind erwartbar (kein Prozess, keine Aufgabe)
    // und dürfen das Update nicht aufhalten: schlimmstenfalls meldet [Files]
    // gleich darauf eine gesperrte Datei, und der Assistent bietet seinen
    // eigenen Ausweg an.
  end;
end;
