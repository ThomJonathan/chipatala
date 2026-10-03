```iss
#define MyAppName "Tumaini Investments"

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppPublisher "Tumaini Investments"
#define MyAppExeName "tumaini_investments.exe"

[Setup]

AppId={{8A7B5C4D-1234-4567-89AB-CDEF12345678}

AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}

CloseApplications=yes

; Install into:
; C:\Program Files\Tumaini Investments\
DefaultDirName={autopf}\Tumaini Investments
DefaultGroupName=Tumaini Investments

; Installer output
OutputDir=installer-output
OutputBaseFilename=Tumaini-Investments-Setup

; Compression
Compression=lzma
SolidCompression=yes

; 64-bit Windows
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Require administrator privileges because we install
; into Program Files
PrivilegesRequired=admin

; ---------------------------------------------------------
; FLUTTER WINDOWS APPLICATION
; ---------------------------------------------------------

[Files]

Source: "build\windows\x64\runner\Release\*"; \
    DestDir: "{app}"; \
    Flags: recursesubdirs createallsubdirs ignoreversion

; ---------------------------------------------------------
; SHORTCUTS
; ---------------------------------------------------------

[Icons]

; Start Menu
Name: "{autoprograms}\Tumaini Investments"; \
    Filename: "{app}\{#MyAppExeName}"; \
    WorkingDir: "{app}"

; Desktop
Name: "{autodesktop}\Tumaini Investments"; \
    Filename: "{app}\{#MyAppExeName}"; \
    WorkingDir: "{app}"; \
    Tasks: desktopicon

; ---------------------------------------------------------
; OPTIONAL DESKTOP SHORTCUT
; ---------------------------------------------------------

[Tasks]

Name: "desktopicon"; \
    Description: "Create a desktop shortcut"; \
    GroupDescription: "Additional shortcuts:"

; ---------------------------------------------------------
; LAUNCH AFTER INSTALLATION
; ---------------------------------------------------------

[Run]

Filename: "{app}\{#MyAppExeName}"; \
    Description: "Launch Tumaini Investments"; \
    Flags: nowait postinstall skipifsilent
```