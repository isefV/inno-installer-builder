# Inno Installer Builder

Turn any folder containing a Windows `.exe` app into an installer with one command.

`build-installer.ps1` finds the main exe, reads its name, version and architecture, writes an [Inno Setup](https://jrsoftware.org/isinfo.php) script, and compiles it into a `Setup.exe`. You can override anything it detects, and there is no per-project configuration to maintain.

## Requirements

- Windows with PowerShell 5.1 or newer
- Inno Setup 6.3 or newer:

  ```powershell
  winget install JRSoftware.InnoSetup
  ```

The script finds Inno Setup through `PATH`, the Windows registry and the usual install folders. If it is somewhere else, pass `-IsccPath`.

## Quick start

```powershell
.\build-installer.ps1 -SourceDir .\dist\MyApp
```

The installer and the generated `.iss` script appear in `.\installers`.

To list every option with examples:

```powershell
.\build-installer.ps1 -h
```

If PowerShell blocks the script, allow it for a single run:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-installer.ps1 -SourceDir .\dist\MyApp
```

## Examples

Set the details yourself and let the user choose the install type:

```powershell
.\build-installer.ps1 -SourceDir .\dist\MyApp `
    -AppName "My App" `
    -AppVersion 2.1.0 `
    -Publisher "Acme" `
    -AppUrl "https://example.com" `
    -InstallScope Ask `
    -IconFile .\app.ico `
    -LicenseFile .\LICENSE.txt `
    -DesktopIcon
```

Choose the main exe when the folder has several:

```powershell
.\build-installer.ps1 -SourceDir .\dist\MyApp -ExeName bin\MyApp.exe
```

Write the `.iss` script without compiling, to review or edit it:

```powershell
.\build-installer.ps1 -SourceDir .\dist\MyApp -ScriptOnly
```

Use the result in a build pipeline. The installer's path is the script's only pipeline output:

```powershell
$setup = .\build-installer.ps1 -SourceDir .\dist\MyApp
```

## Parameters

Only `-SourceDir` is required.

| Parameter | Default | Description |
|---|---|---|
| `-SourceDir` | Required | Folder to package, including subfolders. |
| `-AppName` | Exe's product name, then its file name | Name shown to users. |
| `-AppVersion` | Exe's product version, then file version | Any text, such as `1.2.3` or `1.2.3-beta`. |
| `-ExeName` | Detected | Main exe, relative to `-SourceDir`. |
| `-Publisher` | Exe's company name | Shown in Windows Installed apps. |
| `-AppUrl` | None | Website shown in Windows Installed apps. |
| `-AppId` | Generated from publisher and name | Fixed install identity. See [Upgrades](#upgrades). |
| `-OutputDir` | `.\installers` | Where the installer and `.iss` go. Must be outside `-SourceDir`. |
| `-OutputName` | `<AppName>-<AppVersion>-setup` | Installer file name, without extension. |
| `-IconFile` | Inno Setup's icon | `.ico` for the installer itself. Shortcuts use the exe's own icon. |
| `-LicenseFile` | None | `.txt` or `.rtf` the user must accept during setup. |
| `-InstallScope` | `User` | `User`, `Machine` or `Ask`. See [Install scope](#install-scope). |
| `-Architecture` | `Auto` | `Auto` reads the exe's header. Or `x64`, `x86`, `arm64`. |
| `-DesktopIcon` | Off | Ticks the desktop shortcut option by default. The option is always offered. |
| `-StartupOption` | Off | Offers an unticked "Start with Windows" option. |
| `-NoRunAfterInstall` | Off | Removes the option to launch the app when setup finishes. |
| `-Exclude` | `*.pdb` | File patterns to leave out. Your list replaces the default. |
| `-ExtraIss` | None | Text file of Inno Setup sections to append. See [Custom setup steps](#custom-setup-steps). |
| `-IsccPath` | Detected | Full path to `ISCC.exe`. |
| `-ScriptOnly` | Off | Writes the `.iss` and stops without compiling. |
| `-h`, `-Help` | Off | Shows the options and examples, then exits. `--help` works too. |

## How the main exe is chosen

The script looks in the top level of `-SourceDir` first, then in subfolders. It ignores names that usually aren't the main program, such as `unins*`, `*setup*`, `*install*`, `*update*`, `*crash*` and `*helper*`.

If one exe remains, it uses that one. If several remain, it picks the one matching `-AppName`. Otherwise it stops and lists them so you can choose with `-ExeName`.

## Install scope

| Value | Installs to | Admin prompt |
|---|---|---|
| `User` | `%LOCALAPPDATA%\Programs\<AppName>` | No |
| `Machine` | `Program Files\<AppName>` | Yes |
| `Ask` | The user chooses when setup starts | Only if they choose all users |

## Upgrades

Windows recognizes an installed app by its AppId. The script generates the AppId from the publisher and app name, so a new version with the same values upgrades the existing install instead of adding a second one.

If the app name or publisher might change, set a permanent `-AppId` from your first release:

```powershell
.\build-installer.ps1 -SourceDir .\dist\MyApp -AppId "Acme.MyApp"
```

Changing the name, publisher or AppId of a released app creates a separate install.

## Custom setup steps

Use `-ExtraIss` for anything the parameters don't cover, such as registry entries or file associations. The file holds normal [Inno Setup sections](https://jrsoftware.org/ishelp/):

```ini
[Registry]
Root: HKCU; Subkey: "Software\Acme\MyApp"; ValueType: string; ValueName: "Channel"; ValueData: "stable"; Flags: uninsdeletekey
```

```powershell
.\build-installer.ps1 -SourceDir .\dist\MyApp -ExtraIss .\extra.iss
```

## Silent installs

Installers built with this script accept Inno Setup's standard command-line switches:

```powershell
.\MyApp-1.0-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
```

With `-InstallScope Ask`, add `/CURRENTUSER` or `/ALLUSERS` to choose the scope. To uninstall silently, run `unins000.exe` from the install folder with the same switches.

## Limitations

- **Code signing:** the installer isn't signed, so Windows SmartScreen may warn people who download it. Sign the finished `.exe` with your own certificate.
- **Language:** the setup wizard is in English only. To change that, edit the `[Languages]` section using `-ScriptOnly`.
- **Inno Setup version:** versions before 6.3 fail at compile time because they don't recognize the architecture settings. Update with `winget upgrade JRSoftware.InnoSetup`.

## Inno Setup license

Inno Setup is a separate product and isn't included here. Its [license](https://jrsoftware.org/files/is/license.txt) applies to your use of it, and the authors have [purchase options](https://jrsoftware.org/isorder.php) for commercial users.
