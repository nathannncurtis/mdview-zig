#ifndef MDVIEW_VERSION
  #define MDVIEW_VERSION "0.0.0"
#endif

[Setup]
AppName=mdview
AppVersion={#MDVIEW_VERSION}
AppPublisher=nathannncurtis
AppPublisherURL=https://github.com/nathannncurtis/mdview-zig
DefaultDirName={autopf}\mdview
DefaultGroupName=mdview
OutputBaseFilename=mdview-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern
UninstallDisplayIcon={app}\mdview.exe
ChangesAssociations=yes

[Files]
Source: "zig-out\bin\mdview.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\mdview"; Filename: "{app}\mdview.exe"
Name: "{group}\Uninstall mdview"; Filename: "{uninstallexe}"

[Tasks]
Name: "assocmd"; Description: "Associate .md files with mdview"; GroupDescription: "File associations:"
Name: "assocmarkdown"; Description: "Associate .markdown files with mdview"; GroupDescription: "File associations:"

[Registry]
Root: HKA; Subkey: "Software\Classes\.md"; ValueType: string; ValueName: ""; ValueData: "mdview.MarkdownFile"; Flags: uninsdeletevalue; Tasks: assocmd
Root: HKA; Subkey: "Software\Classes\.markdown"; ValueType: string; ValueName: ""; ValueData: "mdview.MarkdownFile"; Flags: uninsdeletevalue; Tasks: assocmarkdown
Root: HKA; Subkey: "Software\Classes\mdview.MarkdownFile"; ValueType: string; ValueName: ""; ValueData: "Markdown File"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\mdview.MarkdownFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\mdview.exe,0"
Root: HKA; Subkey: "Software\Classes\mdview.MarkdownFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\mdview.exe"" ""%1"""

[Code]
procedure InitializeWizard();
var
  LightTheme: Cardinal;
begin
  if RegQueryDWordValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
    'AppsUseLightTheme', LightTheme) then
  begin
    if LightTheme = 0 then
    begin
      WizardForm.Color := $1E1E1E;
      WizardForm.MainPanel.Color := $252526;
      WizardForm.InnerPage.Color := $1E1E1E;
      WizardForm.PageNameLabel.Font.Color := $FFFFFF;
      WizardForm.PageDescriptionLabel.Font.Color := $CCCCCC;
      WizardForm.WelcomeLabel1.Font.Color := $FFFFFF;
      WizardForm.WelcomeLabel2.Font.Color := $CCCCCC;
      WizardForm.FinishedHeadingLabel.Font.Color := $FFFFFF;
      WizardForm.FinishedLabel.Font.Color := $CCCCCC;
    end;
  end;
end;
