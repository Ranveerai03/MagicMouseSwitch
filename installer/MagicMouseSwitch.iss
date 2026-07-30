#define MyAppName "Magic Mouse Switch"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Ranveer Rai"
#define MyAppExeName "MagicMouseSwitch.Tray.exe"

[Setup]
AppId={{B11E8C98-CE45-41E9-AE10-12B95139AF55}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion=1.0.0.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}
DefaultDirName={localappdata}\Programs\Magic Mouse Switch
DefaultGroupName=Magic Mouse Switch
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\release
OutputBaseFilename=MagicMouseSwitch-Setup-1.0.0
SetupIconFile=..\MagicMouseSwitch.Tray\Assets\MagicMouseSwitch.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
AppMutex=Local\RanveerRai.MagicMouseSwitch.Tray.v1
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "startup"; Description: "Start Magic Mouse Switch with Windows"; GroupDescription: "Startup:"; Flags: checkedonce

[Files]
Source: "..\release\MagicMouseSwitch-1.0.0-win-x64\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Magic Mouse Switch"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Magic Mouse Switch"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Magic Mouse Switch"; ValueData: """{app}\{#MyAppExeName}"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Magic Mouse Switch"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    RegDeleteValue(
      HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'Magic Mouse Switch');

    if SuppressibleMsgBox(
      'Delete Magic Mouse Switch configuration and logs?',
      mbConfirmation,
      MB_YESNO,
      IDNO) = IDYES then
    begin
      DelTree(ExpandConstant('{localappdata}\MagicMouseSwitch'), True, True, True);
    end;
  end;
end;
