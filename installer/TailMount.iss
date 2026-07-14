#define MyAppName "TailMount"
#define MyAppVersion "0.3.0"
#define MyAppPublisher "MMMHT"
#define MyAppURL "https://github.com/MMMHT/SSHDriveMount"
#define MyAppExeName "TailMount.exe"

[Setup]
AppId={{C820A616-6687-4F9D-953F-B9D80628B566}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=TailMount-Setup-{#MyAppVersion}
SetupIconFile=..\assets\TailMount.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
VersionInfoVersion={#MyAppVersion}.0
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=Tailscale SFTP Drive Manager Setup
VersionInfoProductName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "..\TailMount.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\TailMount.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Install-Dependencies.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "installed.marker"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\TailMount.ico"; DestDir: "{app}\assets"; Flags: ignoreversion

[Icons]
Name: "{group}\TailMount"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\卸载 TailMount"; Filename: "{uninstallexe}"
Name: "{autodesktop}\TailMount"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 TailMount"; Flags: nowait postinstall skipifsilent
