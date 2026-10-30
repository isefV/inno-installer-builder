<#
.SYNOPSIS
    Builds a Windows installer (Setup.exe) for any folder that contains an .exe app, using Inno Setup.

.DESCRIPTION
    Point it at a folder. It finds the main .exe, reads its name, version and architecture,
    writes an Inno Setup script (.iss) next to the output, and compiles it. Every value it
    detects can be overridden with an argument.

    The AppId is derived from the publisher and app name, so a new version built with this
    script upgrades the old install in place. Keep -AppName and -Publisher unchanged between
    releases, or pass a fixed -AppId.

    Requires Inno Setup 6.3 or newer:  winget install JRSoftware.InnoSetup

.PARAMETER SourceDir
    Folder holding the built app. Everything inside it is packaged, including subfolders.
.PARAMETER AppName
    Display name. Default: the exe's ProductName, then the exe's file name.
.PARAMETER AppVersion
    Version text, such as 1.2.3 or 1.2.3-beta. Default: the exe's ProductVersion, then FileVersion.
.PARAMETER ExeName
    Main exe, relative to SourceDir, such as MyApp.exe or bin\MyApp.exe. Default: detected.
.PARAMETER Publisher
    Company or author name shown in Windows "Installed apps".
.PARAMETER AppUrl
    Website shown in Windows "Installed apps".
.PARAMETER AppId
    Fixed install identity. Default: a stable GUID derived from Publisher and AppName.
.PARAMETER OutputDir
    Where Setup.exe and the .iss go. Default: .\installers. Must be outside SourceDir.
.PARAMETER OutputName
    Setup file name without extension. Default: <AppName>-<AppVersion>-setup.
.PARAMETER IconFile
    .ico file for Setup.exe itself. The installed shortcuts use the exe's own icon.
.PARAMETER LicenseFile
    .txt or .rtf file the user must accept during setup.
.PARAMETER InstallScope
    User (no admin prompt), Machine (Program Files, admin) or Ask (the user chooses).
.PARAMETER Architecture
    Auto reads it from the exe's header. Or x64, x86, arm64.
.PARAMETER DesktopIcon
    Tick the "Create a desktop shortcut" option by default.
.PARAMETER StartupOption
    Offer an unticked "Start with Windows" option.
.PARAMETER NoRunAfterInstall
    Do not offer to launch the app on the final page.
.PARAMETER Exclude
    File patterns to leave out. Default: *.pdb
.PARAMETER ExtraIss
    Text file of raw Inno Setup sections to append, such as [Registry] entries.
.PARAMETER IsccPath
    Full path to ISCC.exe. Default: searched on PATH, in the registry and in Program Files.
.PARAMETER ScriptOnly
    Write the .iss and stop, without compiling.

.EXAMPLE
    .\build-installer.ps1 -SourceDir .\dist\MyApp

    Detects everything from the exe.

.EXAMPLE
    .\build-installer.ps1 -SourceDir .\dist\MyApp -AppName "My App" -AppVersion 2.1.0 -Publisher "Acme" -InstallScope Ask -IconFile .\app.ico -DesktopIcon
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$SourceDir,
    [string]$AppName,
    [string]$AppVersion,
    [string]$ExeName,
    [string]$Publisher,
    [string]$AppUrl,
    [string]$AppId,
    [string]$OutputDir = '.\installers',
    [string]$OutputName,
    [string]$IconFile,
    [string]$LicenseFile,
    [ValidateSet('User', 'Machine', 'Ask')][string]$InstallScope = 'User',
    [ValidateSet('Auto', 'x64', 'x86', 'arm64')][string]$Architecture = 'Auto',
    [switch]$DesktopIcon,
    [switch]$StartupOption,
    [switch]$NoRunAfterInstall,
    [string[]]$Exclude = @('*.pdb'),
    [string]$ExtraIss,
    [string]$IsccPath,
    [switch]$ScriptOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-InputFile([string]$Path, [string]$ArgName) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$ArgName file not found: $Path"
    }
    return (Get-Item -LiteralPath $Path).FullName
}

# Picks the main exe: the only candidate, or the one named after the app.
function Find-MainExe([string]$Root, [string]$PreferredName) {
    $notMain = 'unins*', '*setup*', '*install*', '*update*', '*crash*', '*helper*', 'vc_redist*', 'dotnet*', 'createdump*'
    foreach ($recurse in $false, $true) {
        $all = @(Get-ChildItem -LiteralPath $Root -Filter '*.exe' -File -Recurse:$recurse)
        if ($all.Count -eq 0) { continue }
        $candidates = @($all | Where-Object { $n = $_.Name; -not ($notMain | Where-Object { $n -like $_ }) })
        if ($candidates.Count -eq 0) { $candidates = $all }
        if ($candidates.Count -eq 1) { return $candidates[0] }
        if ($PreferredName) {
            $wanted = $PreferredName -replace '[^\w]', ''
            $match = @($candidates | Where-Object { ($_.BaseName -replace '[^\w]', '') -ieq $wanted })
            if ($match.Count -eq 1) { return $match[0] }
        }
        $names = ($candidates | ForEach-Object { '  ' + $_.FullName.Substring($Root.Length).TrimStart('\') }) -join "`n"
        throw "Found several possible main programs. Choose one with -ExeName:`n$names"
    }
    throw "No .exe found in $Root"
}

# Reads the target CPU from the PE header.
function Get-ExeArchitecture([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        $stream.Position = 0x3C
        $stream.Position = $reader.ReadInt32() + 4
        switch ($reader.ReadUInt16()) {
            0x8664 { return 'x64' }
            0x014C { return 'x86' }
            0xAA64 { return 'arm64' }
            default { throw "Could not read the architecture of $Path. Pass -Architecture." }
        }
    }
    finally { $stream.Dispose() }
}

function Find-Iscc([string]$Explicit) {
    if ($Explicit) { return (Resolve-InputFile $Explicit '-IsccPath') }

    $onPath = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $found = @()
    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                     'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($key in $uninstallKeys) {
        Get-ChildItem -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Inno Setup *_is1' } | ForEach-Object {
            $location = $_.GetValue('InstallLocation')
            if ($location) { $found += (Join-Path $location 'ISCC.exe') }
        }
    }
    foreach ($base in ${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path $env:LOCALAPPDATA 'Programs')) {
        if ($base -and (Test-Path -LiteralPath $base)) {
            Get-ChildItem -LiteralPath $base -Directory -Filter 'Inno Setup *' -ErrorAction SilentlyContinue | ForEach-Object {
                $found += (Join-Path $_.FullName 'ISCC.exe')
            }
        }
    }
    # Inno's own binaries carry no version metadata, but the folder name has the major version.
    $existing = @($found | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique | Sort-Object -Descending)
    if ($existing.Count -gt 0) { return $existing[0] }

    throw "Inno Setup was not found. Install it with: winget install JRSoftware.InnoSetup`nOr pass its location with -IsccPath."
}

# Inno Setup escaping. In values, { starts a constant, so it is doubled.
function Esc([string]$Value) { return $Value.Replace('{', '{{') }
# Inside a "quoted" parameter, the quote is doubled as well.
function EscQ([string]$Value) { return (Esc $Value).Replace('"', '""') }
# Paths are read literally by the compiler, so only the quote needs doubling.
function PathQ([string]$Value) { return $Value.Replace('"', '""') }
# Removes characters Windows does not allow in file names.
function Get-SafeName([string]$Value) {
    return ($Value -replace '[\\/:*?"<>|]', '').Trim(' ', '.')
}

# --- Inputs ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    throw "Source folder not found: $SourceDir"
}
$SourceDir = (Get-Item -LiteralPath $SourceDir).FullName.TrimEnd('\')

if ($ExeName) {
    $exePath = Join-Path $SourceDir $ExeName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw "-ExeName not found: $exePath" }
    $exe = Get-Item -LiteralPath $exePath
}
else {
    $exe = Find-MainExe $SourceDir $AppName
}
$exeRelative = $exe.FullName.Substring($SourceDir.Length).TrimStart('\')
$info = $exe.VersionInfo

if (-not $AppName) {
    $AppName = if ($info.ProductName -and $info.ProductName.Trim()) { $info.ProductName.Trim() } else { $exe.BaseName }
}
if (-not $AppVersion) {
    foreach ($candidate in $info.ProductVersion, $info.FileVersion) {
        if ($candidate -and $candidate.Trim()) {
            # Windows metadata often looks like "1.2.3.0 (build-info)".
            $AppVersion = ($candidate.Trim() -split '\s+')[0]
            break
        }
    }
    if (-not $AppVersion) { throw "$($exe.Name) has no version information. Pass -AppVersion." }
}
if (-not $Publisher) {
    $Publisher = if ($info.CompanyName -and $info.CompanyName.Trim()) { $info.CompanyName.Trim() } else { '' }
}
if ($Architecture -eq 'Auto') { $Architecture = Get-ExeArchitecture $exe.FullName }

if (-not $AppId) {
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $seed = [Text.Encoding]::UTF8.GetBytes(("$Publisher|$AppName").ToLowerInvariant())
        $AppId = '{' + (New-Object Guid (, $md5.ComputeHash($seed))).ToString().ToUpperInvariant() + '}'
    }
    finally { $md5.Dispose() }
}

$safeName = Get-SafeName $AppName
if (-not $safeName) { throw "-AppName has no characters that can be used in a folder name: $AppName" }
if (-not $OutputName) { $OutputName = ("$AppName-$AppVersion-setup" -replace '[^\p{L}\p{N}._-]+', '-').Trim('-', '.') }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Get-Item -LiteralPath $OutputDir).FullName.TrimEnd('\')
if (($OutputDir + '\').StartsWith($SourceDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "-OutputDir must be outside the source folder, or the installer would package itself: $OutputDir"
}

# --- Script generation ----------------------------------------------------------------

$setup = New-Object Collections.Generic.List[string]
$setup.Add('[Setup]')
# A leading { in AppId has to be doubled; the closing } does not.
$setup.Add("AppId=$(Esc $AppId)")
$setup.Add("AppName=$(Esc $AppName)")
$setup.Add("AppVersion=$(Esc $AppVersion)")
if ($Publisher) { $setup.Add("AppPublisher=$(Esc $Publisher)") }
if ($AppUrl) {
    $setup.Add("AppPublisherURL=$(Esc $AppUrl)")
    $setup.Add("AppSupportURL=$(Esc $AppUrl)")
}
$setup.Add("DefaultDirName={autopf}\$(Esc $safeName)")
$setup.Add("DefaultGroupName=$(Esc $safeName)")
$setup.Add('DisableProgramGroupPage=yes')
$setup.Add("UninstallDisplayIcon={app}\$(Esc $exeRelative)")
$setup.Add("OutputDir=$OutputDir")
$setup.Add("OutputBaseFilename=$OutputName")
$setup.Add('Compression=lzma2/max')
$setup.Add('SolidCompression=yes')
$setup.Add('WizardStyle=modern')

# VersionInfoVersion accepts numbers only, so 1.2.3-beta is stored as 1.2.3.
if ($AppVersion -match '^\d+(\.\d+){0,3}') { $setup.Add("VersionInfoVersion=$($Matches[0])") }

switch ($InstallScope) {
    'User' { $setup.Add('PrivilegesRequired=lowest') }
    'Machine' { $setup.Add('PrivilegesRequired=admin') }
    'Ask' {
        $setup.Add('PrivilegesRequired=lowest')
        $setup.Add('PrivilegesRequiredOverridesAllowed=dialog commandline')
    }
}
switch ($Architecture) {
    'x64' {
        $setup.Add('ArchitecturesAllowed=x64compatible')
        $setup.Add('ArchitecturesInstallIn64BitMode=x64compatible')
    }
    'arm64' {
        $setup.Add('ArchitecturesAllowed=arm64')
        $setup.Add('ArchitecturesInstallIn64BitMode=arm64')
    }
}
if ($IconFile) { $setup.Add("SetupIconFile=$(Resolve-InputFile $IconFile '-IconFile')") }
if ($LicenseFile) { $setup.Add("LicenseFile=$(Resolve-InputFile $LicenseFile '-LicenseFile')") }

$desktopFlags = if ($DesktopIcon) { '' } else { '; Flags: unchecked' }
$exeInApp = "{app}\$(EscQ $exeRelative)"
$quotedName = EscQ $safeName
$accelSafeName = (EscQ $AppName).Replace('&', '&&')

$tasks = New-Object Collections.Generic.List[string]
$tasks.Add('[Tasks]')
$tasks.Add("Name: ""desktopicon""; Description: ""Create a &desktop shortcut""; GroupDescription: ""Additional shortcuts:""$desktopFlags")
if ($StartupOption) {
    $tasks.Add('Name: "startup"; Description: "Start with &Windows"; GroupDescription: "Additional shortcuts:"; Flags: unchecked')
}

$excludeValue = (@($Exclude) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ','
$excludeParam = if ($excludeValue) { "; Excludes: ""$(PathQ $excludeValue)""" } else { '' }

$files = @(
    '[Files]'
    "Source: ""$(PathQ $SourceDir)\*""; DestDir: ""{app}""$excludeParam; Flags: ignoreversion recursesubdirs createallsubdirs"
)
$icons = New-Object Collections.Generic.List[string]
$icons.Add('[Icons]')
$icons.Add("Name: ""{autoprograms}\$quotedName""; Filename: ""$exeInApp""")
$icons.Add("Name: ""{autodesktop}\$quotedName""; Filename: ""$exeInApp""; Tasks: desktopicon")
if ($StartupOption) { $icons.Add("Name: ""{autostartup}\$quotedName""; Filename: ""$exeInApp""; Tasks: startup") }

$sections = New-Object Collections.Generic.List[string]
$sections.Add("; Generated by build-installer.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
# Stops the preprocessor treating {# inside an app name or path as code.
$sections.Add('#pragma inlinestart "<<ispp-off>>"')
$sections.AddRange([string[]]$setup)
$sections.Add('')
$sections.Add('[Languages]')
$sections.Add('Name: "english"; MessagesFile: "compiler:Default.isl"')
$sections.Add('')
$sections.AddRange([string[]]$tasks)
$sections.Add('')
$sections.AddRange([string[]]$files)
$sections.Add('')
$sections.AddRange([string[]]$icons)
if (-not $NoRunAfterInstall) {
    $sections.Add('')
    $sections.Add('[Run]')
    # shellexec lets an app whose manifest demands admin rights start from a user-level setup.
    $sections.Add("Filename: ""$exeInApp""; Description: ""Launch $accelSafeName""; Flags: nowait postinstall skipifsilent shellexec")
}
if ($ExtraIss) {
    $sections.Add('')
    $sections.Add('#pragma inlinestart "{#"')
    $sections.Add((Get-Content -LiteralPath (Resolve-InputFile $ExtraIss '-ExtraIss') -Raw -Encoding UTF8))
}

$issPath = Join-Path $OutputDir "$OutputName.iss"
# ISCC reads Unicode scripts correctly only when they carry a UTF-8 byte order mark.
[IO.File]::WriteAllText($issPath, (($sections -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))

Write-Host "App:          $AppName $AppVersion ($Architecture)"
Write-Host "Main exe:     $exeRelative"
Write-Host "Install for:  $InstallScope"
Write-Host "AppId:        $AppId"
Write-Host "Script:       $issPath"

if ($ScriptOnly) { return }

# --- Compile --------------------------------------------------------------------------

$iscc = Find-Iscc $IsccPath
Write-Host "Compiler:     $iscc"

& $iscc '/Qp' $issPath
if ($LASTEXITCODE -ne 0) {
    throw "ISCC failed with exit code $LASTEXITCODE. The script it compiled is $issPath`nIf it reports an unknown architecture, Inno Setup is older than 6.3. Update with: winget upgrade JRSoftware.InnoSetup"
}

$setupPath = Join-Path $OutputDir "$OutputName.exe"
$sizeMb = [math]::Round((Get-Item -LiteralPath $setupPath).Length / 1MB, 2)
Write-Host "Installer:    $setupPath ($sizeMb MB)"
Write-Output $setupPath
