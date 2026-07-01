<#
.SYNOPSIS
Builds a small CMake-consumable WinUI 3 / Windows App SDK snapshot.

.DESCRIPTION
Downloads pinned Microsoft.WindowsAppSDK and Microsoft.Windows.CppWinRT NuGet
packages, generates C++/WinRT projection headers from the Windows App SDK
metadata, collects public headers/import libraries/metadata, writes a CMake
package config, and produces a versioned zip in artifacts/.

This is intended for programmatic, no-XAML WinUI 3 C++ applications. It does
not run XamlCompiler, MIDL, app PRI generation, or MSBuild WinUI targets for the
consumer. When runtime DLLs are included it does bundle the framework resource
indexes (.pri) shipped by the Windows App SDK, which an unpackaged app needs so
WinUI can resolve its control/theme resources at run time.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WindowsAppSDKVersion,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CppWinRTVersion,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeRuntimeDlls,

    [Parameter(Mandatory = $false)]
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-CleanDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Copy-ArchitectureFile {
    param(
        [Parameter(Mandatory = $true)]$File,
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        [Parameter(Mandatory = $true)][string]$SubDirectory
    )

    $normalized = $File.FullName.Replace('\', '/')
    $arch = $null

    if ($normalized -match '(^|/)(win-)?x64(/|$)' -or $normalized -match '(^|/)x64_') {
        $arch = "x64"
    }
    elseif ($normalized -match '(^|/)(win-)?arm64(/|$)' -or $normalized -match '(^|/)arm64_') {
        $arch = "arm64"
    }
    elseif ($normalized -match '(^|/)(win-)?x86(/|$)' -or $normalized -match '(^|/)x86_') {
        $arch = "x86"
    }

    if ($arch) {
        $destination = Join-Path $SdkRoot (Join-Path $SubDirectory $arch)
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -LiteralPath $File.FullName -Destination $destination -Force
        Write-Host "Copied $($File.Name) for $arch -> $destination"
    }
    else {
        Write-Warning "Could not infer architecture for '$($File.FullName)'; skipping."
    }
}

function Get-PackageRoot {
    param(
        [Parameter(Mandatory = $true)][string]$PackagesRoot,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $expected = Join-Path $PackagesRoot "$PackageId.$Version"
    if (Test-Path $expected) {
        return (Resolve-Path $expected).Path
    }

    $package = Get-ChildItem -LiteralPath $PackagesRoot -Directory |
        Where-Object { $_.Name -ieq "$PackageId.$Version" -or $_.Name -like "$PackageId.*" } |
        Sort-Object Name |
        Select-Object -First 1

    if (!$package) {
        throw "Package '$PackageId' version '$Version' was not found under '$PackagesRoot'."
    }

    return $package.FullName
}

function Get-WindowsSdkWinmdDirectories {
    param([Parameter(Mandatory = $true)][string]$PackagesRoot)

    $searchRoots = @()
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\UnionMetadata"
    if (Test-Path $kitsRoot) {
        $searchRoots += $kitsRoot
    }

    $windowsSdkBuildToolsRoots = @(Get-ChildItem -LiteralPath $PackagesRoot -Directory |
        Where-Object { $_.Name -like "Microsoft.Windows.SDK.BuildTools*" } |
        ForEach-Object { $_.FullName })
    $searchRoots += $windowsSdkBuildToolsRoots

    if (!$searchRoots) {
        return @()
    }

    return @($searchRoots |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "Windows.winmd" } |
        Sort-Object FullName -Descending |
        ForEach-Object { $_.Directory.FullName } |
        Sort-Object -Unique)
}

$packagesRoot = Join-Path $RepositoryRoot "packages"
$outRoot = Join-Path $RepositoryRoot "out"
$sdkRoot = Join-Path $outRoot "WinUI3SDK"
$includeRoot = Join-Path $sdkRoot "include"
$winmdOut = Join-Path $sdkRoot "winmd"
$cmakeOut = Join-Path $sdkRoot "cmake"
$artifactsRoot = Join-Path $RepositoryRoot "artifacts"
$configTemplatePath = Join-Path $RepositoryRoot "cmake\WinUI3SDKConfig.cmake"

if (!(Test-Path $configTemplatePath)) {
    throw "CMake package config template was not found: $configTemplatePath"
}

New-CleanDirectory -Path $packagesRoot
New-CleanDirectory -Path $outRoot
New-CleanDirectory -Path $artifactsRoot

Write-Host "Installing NuGet packages..."
nuget install Microsoft.WindowsAppSDK -Version $WindowsAppSDKVersion -OutputDirectory $packagesRoot -NonInteractive -Verbosity normal
nuget install Microsoft.Windows.CppWinRT -Version $CppWinRTVersion -OutputDirectory $packagesRoot -NonInteractive -Verbosity normal

$windowsAppSdkRoot = Get-PackageRoot -PackagesRoot $packagesRoot -PackageId "Microsoft.WindowsAppSDK" -Version $WindowsAppSDKVersion
$cppWinRTRoot = Get-PackageRoot -PackagesRoot $packagesRoot -PackageId "Microsoft.Windows.CppWinRT" -Version $CppWinRTVersion

$packageRoots = @(Get-ChildItem -LiteralPath $packagesRoot -Directory | Sort-Object Name)
$windowsAppSdkPackageRoots = @($packageRoots | Where-Object { $_.Name -like "Microsoft.WindowsAppSDK*" } | ForEach-Object { $_.FullName })
$metadataPackageRoots = @($packageRoots |
    Where-Object { $_.Name -notlike "Microsoft.Windows.CppWinRT*" -and $_.Name -notlike "Microsoft.Windows.SDK.BuildTools*" } |
    ForEach-Object { $_.FullName })
$runtimeDllPackageRoots = $metadataPackageRoots

foreach ($root in $windowsAppSdkPackageRoots) {
    Write-Host "Windows App SDK package root: $root"
}

$cppwinrt = Get-ChildItem -LiteralPath $cppWinRTRoot -Recurse -File -Filter cppwinrt.exe | Select-Object -First 1
if (!$cppwinrt) {
    throw "cppwinrt.exe was not found under '$cppWinRTRoot'."
}

New-Item -ItemType Directory -Force -Path $includeRoot, $winmdOut, $cmakeOut | Out-Null

Write-Host "Finding metadata..."
$packageWinmdFiles = @($metadataPackageRoots |
    ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter *.winmd } |
    Where-Object { $_.FullName -notmatch '\\ref\\net' } |
    Sort-Object FullName -Unique)
if (!$packageWinmdFiles) {
    throw "No .winmd files were found under installed metadata package roots."
}

$windowsSdkWinmdDirectories = @(Get-WindowsSdkWinmdDirectories -PackagesRoot $packagesRoot)
if (!$windowsSdkWinmdDirectories) {
    Write-Warning "Windows SDK Windows.winmd was not found in Windows Kits or NuGet SDK build tools. cppwinrt.exe may fail if Windows metadata cannot be resolved implicitly."
}

$winmdDirs = @($windowsSdkWinmdDirectories + @($packageWinmdFiles | ForEach-Object { $_.Directory.FullName }) |
    Sort-Object -Unique)

foreach ($dir in $winmdDirs) {
    Write-Host "WINMD input directory: $dir"
}

Write-Host "Generating C++/WinRT projection headers..."
$cppwinrtArgs = @()
foreach ($dir in $winmdDirs) {
    $cppwinrtArgs += @("-input", $dir)
}
$cppwinrtArgs += @("-output", $includeRoot)
& $cppwinrt.FullName @cppwinrtArgs
if ($LASTEXITCODE -ne 0) {
    throw "cppwinrt.exe failed with exit code $LASTEXITCODE."
}

if (!(Test-Path (Join-Path $includeRoot "winrt\base.h"))) {
    throw "C++/WinRT generation completed, but winrt/base.h was not found in '$includeRoot'."
}

Write-Host "Copying Windows App SDK public headers..."
# Bundle every flat header the Windows App SDK ships in its package include dirs.
# These are the App SDK's own headers (MddBootstrap, the version info, and the
# microsoft.ui.* / interop headers such as microsoft.ui.xaml.window.h that declare
# IWindowNative). The Windows SDK does not ship the microsoft.ui.* set, so a
# consumer can only get them from here. A few names overlap with the Windows SDK
# (e.g. dwrite.h); copying them too is harmless and keeps this simple.
$headerCopyCount = 0
foreach ($root in $windowsAppSdkPackageRoots) {
    $packageInclude = Join-Path $root "include"
    if (!(Test-Path $packageInclude)) {
        continue
    }

    Get-ChildItem -LiteralPath $packageInclude -File -Filter *.h | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $includeRoot -Force
        $headerCopyCount++
        Write-Host "Copied $($_.Name) -> $includeRoot"
    }
}

if ($headerCopyCount -eq 0) {
    throw "No flat headers were found under any Windows App SDK package include directory."
}

# Sanity-check the headers the consuming app links against directly.
$requiredHeaders = @("MddBootstrap.h", "WindowsAppSDK-VersionInfo.h", "microsoft.ui.xaml.window.h")
foreach ($header in $requiredHeaders) {
    if (!(Test-Path (Join-Path $includeRoot $header))) {
        throw "Required header '$header' was not bundled from any Windows App SDK package include directory."
    }
}

Write-Host "Copying import libraries..."
foreach ($arch in @("x64", "arm64", "x86")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $sdkRoot "lib\$arch") | Out-Null
}

$bootstrapLibs = @($windowsAppSdkPackageRoots |
    ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "Microsoft.WindowsAppRuntime.Bootstrap.lib" } |
    Sort-Object FullName -Unique)
if (!$bootstrapLibs) {
    throw "Microsoft.WindowsAppRuntime.Bootstrap.lib was not found under any Windows App SDK package root."
}
foreach ($lib in $bootstrapLibs) {
    Copy-ArchitectureFile -File $lib -SdkRoot $sdkRoot -SubDirectory "lib"
}

if ($IncludeRuntimeDlls) {
    Write-Host "Including runtime DLLs. Verify Microsoft Windows App SDK redistribution and deployment requirements before publishing this artifact."
    foreach ($arch in @("x64", "arm64", "x86")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $sdkRoot "bin\$arch") | Out-Null
    }

    $runtimeDlls = @($runtimeDllPackageRoots |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "*.dll" } |
        Where-Object {
            $normalized = $_.FullName.Replace('\', '/')
            $_.Name -eq "Microsoft.WindowsAppRuntime.Bootstrap.dll" -or
                $normalized -match '/runtimes(-framework)?/win-(x64|arm64|x86)/native/'
        } |
        Sort-Object FullName -Unique)

    if (!$runtimeDlls) {
        throw "No runtime DLLs were found under installed runtime package roots."
    }

    $runtimeDlls |
        ForEach-Object { Copy-ArchitectureFile -File $_ -SdkRoot $sdkRoot -SubDirectory "bin" }

    # WinUI 3 resolves its control styles and theme resources (e.g.
    # ms-appx:///Microsoft.UI.Xaml/Themes/themeresources.xaml) through MRT. An
    # unpackaged app has no package identity, so MRT cannot reach the framework
    # package's resources; instead it auto-loads a file named resources.pri sitting
    # next to the executable. The WinUI control/theme resource index that carries
    # those XBF resources is Microsoft.UI.Xaml.Controls.pri (it embeds
    # themeresources/generic), so deploy it renamed to resources.pri. The theme also
    # references a couple of real files by path (Microsoft.UI.Xaml\Assets\*), so the
    # Microsoft.UI.Xaml\Assets folder must travel alongside. Without these an
    # unpackaged app cannot locate themeresources.xaml and no window appears.
    #
    # (Consuming the resources still requires the app itself to implement
    # IXamlMetadataProvider; see README "Runtime nuances".)
    Write-Host "Deploying WinUI resource index (resources.pri) and theme assets..."
    foreach ($arch in @("x64", "arm64", "x86")) {
        $controlsPri = $runtimeDllPackageRoots |
            ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "Microsoft.UI.Xaml.Controls.pri" -ErrorAction SilentlyContinue } |
            Where-Object { $_.FullName.Replace('\', '/') -match "/win-$arch/native/" } |
            Select-Object -First 1

        if (!$controlsPri) {
            Write-Warning "Microsoft.UI.Xaml.Controls.pri not found for $arch; WinUI theme resources will not load."
            continue
        }

        $archBin = Join-Path $sdkRoot "bin\$arch"
        New-Item -ItemType Directory -Force -Path $archBin | Out-Null
        Copy-Item -LiteralPath $controlsPri.FullName -Destination (Join-Path $archBin "resources.pri") -Force
        Write-Host "resources.pri ($arch) <- $($controlsPri.FullName)"

        # Theme resources reference asset files (e.g. NoiseAsset_256x256_PNG.png) by
        # path, relative to the exe. Preserve the Microsoft.UI.Xaml\Assets layout.
        $assetsDir = Join-Path $controlsPri.DirectoryName "Microsoft.UI.Xaml\Assets"
        if (Test-Path $assetsDir) {
            $assetsParent = Join-Path $archBin "Microsoft.UI.Xaml"
            New-Item -ItemType Directory -Force -Path $assetsParent | Out-Null
            Copy-Item -LiteralPath $assetsDir -Destination $assetsParent -Recurse -Force
            Write-Host "Assets ($arch) <- $assetsDir"
        }
        else {
            Write-Warning "WinUI theme assets not found for $arch at $assetsDir"
        }
    }
}

Write-Host "Copying metadata..."
$seenWinmdNames = @{}
foreach ($winmd in $packageWinmdFiles) {
    if (!$seenWinmdNames.ContainsKey($winmd.Name)) {
        Copy-Item -LiteralPath $winmd.FullName -Destination $winmdOut -Force
        $seenWinmdNames[$winmd.Name] = $winmd.FullName
    }
}

Write-Host "Writing CMake package config..."
$configPath = Join-Path $cmakeOut "WinUI3SDKConfig.cmake"
Copy-Item -LiteralPath $configTemplatePath -Destination $configPath -Force

$versionPath = Join-Path $sdkRoot "VERSION.txt"
@"
Microsoft.WindowsAppSDK=$WindowsAppSDKVersion
Microsoft.Windows.CppWinRT=$CppWinRTVersion
Configuration=$Configuration
IncludeRuntimeDlls=$($IncludeRuntimeDlls.IsPresent)
"@ | Set-Content -LiteralPath $versionPath -Encoding UTF8

$zipName = "winui3-sdk-$WindowsAppSDKVersion-cppwinrt-$CppWinRTVersion.zip"
$zipPath = Join-Path $artifactsRoot $zipName
Write-Host "Creating $zipPath..."
Compress-Archive -Path $sdkRoot -DestinationPath $zipPath -Force

Write-Host "Created SDK snapshot: $zipPath"