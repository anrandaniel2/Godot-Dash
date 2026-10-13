; One per-user app identity for every build. Never touch the user-data folder.
#ifndef PayloadDir
  #error PayloadDir must point at the verified Windows export
#endif
#ifndef BuildVersion
  #define BuildVersion "1.0.0"
#endif
#ifndef BuildId
  #define BuildId "local"
#endif

[Setup]
AppId=GodotDash
AppName=Godot Dash
AppVersion={#BuildVersion}
AppVerName=Godot Dash ({#BuildId})
AppPublisher=Godot Dash
DefaultDirName={localappdata}\Programs\Godot Dash
DefaultGroupName=Godot Dash
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UsePreviousAppDir=yes
UsePreviousTasks=yes
DisableDirPage=auto
DisableProgramGroupPage=yes
UninstallDisplayName=Godot Dash
UninstallDisplayIcon={app}\Godot Dash.exe
OutputBaseFilename=GodotDashSetup-x86_64
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=Godot Dash.exe,godot-dash.exe,*.dll,*.pck
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: checkedonce

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Godot Dash"; Filename: "{app}\Godot Dash.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Godot Dash"; Filename: "{app}\Godot Dash.exe"; WorkingDir: "{app}"; Tasks: desktopicon

; Only obsolete application binaries, never levels, settings or arbitrary files.
[InstallDelete]
Type: files; Name: "{app}\godot-dash.exe"
Type: files; Name: "{app}\godot-dash.console.exe"
Type: files; Name: "{app}\godot-dash.pck"

[Run]
Filename: "{app}\Godot Dash.exe"; Description: "Launch Godot Dash"; Flags: nowait postinstall skipifsilent
