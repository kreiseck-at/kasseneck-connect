; Inno-Setup-Skript für Kasseneck Connect (Windows).
;
;   ISCC.exe /DAppVersion=0.1.0 tool\installer\windows\KasseneckConnect.iss
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
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\..\build
OutputBaseFilename=KasseneckConnect-{#AppVersion}-windows-x64-setup
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
