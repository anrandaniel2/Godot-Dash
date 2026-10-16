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
DefaultDirName={code:GetDefaultInstallDir}
DefaultGroupName=Godot Dash
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Pick a previous directory ourselves, only when this non-elevated installer can write there.
UsePreviousAppDir=no
UsePreviousTasks=no
DisableDirPage=auto
DisableProgramGroupPage=yes
UninstallDisplayName=Godot Dash
UninstallDisplayIcon={app}\Godot Dash.exe
OutputBaseFilename=GodotDashSetup-x86_64
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
SetupMutex=GodotDash-Installer
CloseApplications=yes
CloseApplicationsFilter=Godot Dash.exe,Godot Dash.pck,RenderingServer\Godot Dash.exe,RenderingServer\Godot Dash.pck,GDClone\Godot Dash.exe,GDClone\Godot Dash.pck,OpenDash\Godot Dash.exe,OpenDash\Godot Dash.pck,libgdash_native.windows.template_release.x86_64.dll
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"

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

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\GodotDash_is1';

var
  PreviousInstallNotWritable: Boolean;

function CanWriteToDirectory(const Directory: String): Boolean;
var
  TestDirectory: String;
begin
  Result := False;
  if Directory = '' then
    Exit;
  if not ForceDirectories(Directory) then
    Exit;
  TestDirectory := AddBackslash(Directory) + '.gdash-setup-write-test-' + IntToStr(Random(2147483647));
  if not CreateDir(TestDirectory) then
    Exit;
  RemoveDir(TestDirectory);
  Result := True;
end;

function GetDefaultInstallDir(Param: String): String;
var
  PreviousDirectory: String;
  FoundPrevious: Boolean;
begin
  Result := ExpandConstant('{localappdata}\Programs\Godot Dash');
  FoundPrevious := RegQueryStringValue(HKCU, UninstallKey, 'InstallLocation', PreviousDirectory);
  if not FoundPrevious then
    FoundPrevious := RegQueryStringValue(HKLM, UninstallKey, 'InstallLocation', PreviousDirectory);
  if FoundPrevious then begin
    if CanWriteToDirectory(PreviousDirectory) then
      Result := PreviousDirectory
    else
      PreviousInstallNotWritable := True;
  end;
end;

procedure InitializeWizard;
begin
  if PreviousInstallNotWritable then
    MsgBox(
      'The previous installation folder is not writable by this Windows account.' + #13#10 + #13#10 +
      'Setup will use your per-user Programs folder instead. Your saved levels and settings in ' +
      '%APPDATA%\godot-dash are unchanged. An old machine-wide copy may need to be removed separately.',
      mbInformation, MB_OK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then
    if not CanWriteToDirectory(WizardDirValue) then begin
      MsgBox(
        'This folder cannot be written by the current Windows account. Choose a folder under ' +
        'your user profile, such as %LOCALAPPDATA%\Programs\Godot Dash.',
        mbError, MB_OK);
      Result := False;
    end;
end;
