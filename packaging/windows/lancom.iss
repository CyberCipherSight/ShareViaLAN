#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef MyOutputDir
  #define MyOutputDir AddBackslash(SourcePath) + "..\\..\\dist\\windows"
#endif

#define MyAppName "ShareViaLAN"
#define MyAppPublisher "ShareViaLAN"
#define MyAppExeName "lancom.exe"
#define RootDir AddBackslash(SourcePath) + "..\\..\\"
#define BuildOutputDir AddBackslash(SourcePath) + "..\\..\\build\\windows\\x64\\runner\\Release\\"

[Setup]
AppId={{0E4FA22A-A560-4E8A-9E21-F3D66438F704}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename=ShareViaLAN-Setup-{#MyAppVersion}
SetupIconFile={#RootDir}windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"
Name: "firewall"; Description: "Allow ShareViaLAN on private LAN networks"; GroupDescription: "Network access:"; Flags: checkedonce

[Files]
Source: "{#BuildOutputDir}*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""ShareViaLAN TCP 9002"" dir=in action=allow program=""{app}\{#MyAppExeName}"" protocol=TCP localport=9002 profile=private remoteip=localsubnet"; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""ShareViaLAN UDP 9001"" dir=in action=allow program=""{app}\{#MyAppExeName}"" protocol=UDP localport=9001 profile=private remoteip=localsubnet"; Flags: runhidden; Tasks: firewall
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ShareViaLAN TCP 9002"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""ShareViaLAN UDP 9001"""; Flags: runhidden
