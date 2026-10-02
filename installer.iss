#define MyAppName "Tumaini Investments"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Tumaini Investments"
#define MyAppExeName "tumaini_investments.exe"

[Setup]
AppId={{8A7B5C4D-1234-4567-89AB-CDEF12345678}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}

DefaultDirName={autopf}\Tumaini Investments
DefaultGroupName=Tumaini Investments

OutputDir=installer-output
OutputBaseFilename=Tumaini-Investments-Setup

Compression=lzma
SolidCompression=yes

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64

PrivilegesRequired=admin

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Tumaini Investments"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Tumaini Investments"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Tumaini Investments"; Flags: nowait postinstall skipifsilent