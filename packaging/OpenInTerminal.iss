; Compiled by scripts/build-installer.ps1. Payload paths are supplied as ISPP defines.
#ifndef AppVersion
  #error Run scripts/build-installer.ps1 to compile this installer.
#endif

[Setup]
AppId={{895962A4-9AA3-44AC-B5EB-33044CF05043}
AppName=Open In Terminal
AppVersion={#AppVersion}
AppPublisher=Open In Terminal
DefaultDirName={localappdata}\Programs\OpenInTerminal
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.22000
#if AppArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; Explorer loads the optional classic extension in-process: do not allow x64 on ARM64.
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
#endif
OutputDir={#InstallerOutput}
OutputBaseFilename=OpenInTerminal-{#AppVersion}-{#AppArchitecture}-setup{#BuildSuffix}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Open In Terminal
SetupIconFile={#PackageDirectory}\Assets\OpenInTerminal.ico
UninstallDisplayIcon={app}\OpenInTerminal.ico
; Versioned payloads avoid replacing DLLs currently loaded by Explorer.
CloseApplications=no
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "classic"; Description: "Also add to the classic context menu (Directory Opus / Show more options)"; Flags: unchecked

[Files]
Source: "{#PackageDirectory}\Assets\OpenInTerminal.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#PackageDirectory}\*"; DestDir: "{app}\packages\{#PayloadId}"; Flags: ignoreversion onlyifdoesntexist recursesubdirs createallsubdirs
#ifdef SignedMsixPath
Source: "{#SignedMsixPath}"; DestDir: "{app}\packages\{#PayloadId}"; DestName: "Signed.msix"; Flags: ignoreversion onlyifdoesntexist
#endif
Source: "{#ProjectRoot}\scripts\install.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\uninstall.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\setup.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\stop-extension-host.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "{#ProjectRoot}\scripts\get-package-location.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
; Run registration while installation can still roll back copied files on an exception.
Source: "{#ProjectRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion; AfterInstall: RegisterPackage

[UninstallDelete]
; Windows creates this empty metadata directory during development registration.
Type: dirifempty; Name: "{app}\packages\{#PayloadId}\microsoft.system.package.metadata"
Type: dirifempty; Name: "{app}\packages\{#PayloadId}"
Type: dirifempty; Name: "{app}\packages"
Type: dirifempty; Name: "{app}"

[Code]
var
  RegistrationFailed: Boolean;

procedure FailRegistration(MessageText: String);
begin
  RegistrationFailed := True;
  Log(MessageText);
  SuppressibleMsgBox(MessageText, mbError, MB_OK, IDOK);
  { AfterInstall script exceptions do not cancel Inno. Request cancellation so its
    next native checkpoint rolls back the installation and returns a failing status. }
  WizardForm.CancelButton.Enabled := True;
  if WizardSilent then WizardForm.Show;
  WizardForm.Close;
  if WizardSilent then WizardForm.Hide;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if RegistrationFailed then begin
    Cancel := True;
    Confirm := False;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if RegistrationFailed then Result := 1 else Result := 0;
end;

function PowerShellPath: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
#ifndef SignedMsixPath
var
  DeveloperMode: Cardinal;
#endif
begin
  Result := '';
#ifndef SignedMsixPath
  if not RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock',
    'AllowDevelopmentWithoutDevLicense', DeveloperMode) or (DeveloperMode <> 1) then
    Result := 'This development installer requires Windows Developer Mode. Enable it in Windows Settings and retry, or use a release installer containing a trusted, signed MSIX. Setup does not change this setting or install certificates.';
#endif
end;

procedure RegisterPackage;
var
  Params, DeploymentLog: String;
  ExitCode: Integer;
begin
  DeploymentLog := ExpandConstant('{localappdata}\OpenInTerminal\install.log');
  ForceDirectories(ExtractFileDir(DeploymentLog));
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{app}\scripts\setup.ps1')) + ' -Action Install -PackageDirectory ' +
    AddQuotes(ExpandConstant('{app}\packages\{#PayloadId}')) + ' -LogPath ' + AddQuotes(DeploymentLog);
#ifdef SignedMsixPath
  Params := Params + ' -SignedMsixPath ' + AddQuotes(ExpandConstant('{app}\packages\{#PayloadId}\Signed.msix'));
#endif
  if WizardIsTaskSelected('classic') then
    Params := Params + ' -IncludeClassicMenu';
  if not Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    FailRegistration('Could not start Windows PowerShell to register the context menu.');
  if ExitCode <> 0 then
    FailRegistration('Context menu registration failed. See ' + DeploymentLog);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Params, DeploymentLog: String;
  ExitCode: Integer;
begin
  if CurUninstallStep <> usUninstall then Exit;
  DeploymentLog := ExpandConstant('{localappdata}\OpenInTerminal\uninstall.log');
  ForceDirectories(ExtractFileDir(DeploymentLog));
  Params := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{app}\scripts\setup.ps1')) + ' -Action Uninstall -LogPath ' + AddQuotes(DeploymentLog);
  if not Exec(PowerShellPath, Params, '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
    RaiseException('Could not start Windows PowerShell to unregister the context menu.');
  if ExitCode <> 0 then
    RaiseException('Could not unregister the context menu. See ' + DeploymentLog);
end;

[Messages]
FinishedLabel=Open In Terminal has been installed. Open a new File Explorer window to use the menu. Hold Ctrl while clicking a profile to run as administrator.
