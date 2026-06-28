<#
.SYNOPSIS
Builds a small CMake-consumable WinUI 3 / Windows App SDK snapshot.

.DESCRIPTION
Downloads pinned Microsoft.WindowsAppSDK and Microsoft.Windows.CppWinRT NuGet
packages, generates C++/WinRT projection headers from the Windows App SDK
metadata, collects public headers/import libraries/metadata, writes a CMake
package config, and produces a versioned zip in artifacts/.

This is intended for programmatic, no-XAML WinUI 3 C++ applications. It does
not run XamlCompiler, MIDL, PRI generation, or MSBuild WinUI targets for the
consumer.
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
$requiredHeaders = @("MddBootstrap.h", "WindowsAppSDK-VersionInfo.h")
foreach ($header in $requiredHeaders) {
    $file = $windowsAppSdkPackageRoots |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter $header } |
        Select-Object -First 1
    if (!$file) {
        throw "Required header '$header' was not found under any Windows App SDK package root."
    }

    Copy-Item -LiteralPath $file.FullName -Destination $includeRoot -Force
    Write-Host "Copied $($file.FullName) -> $includeRoot"
}

$additionalHeaders = @(
    "MddBootstrapTest.h",
    "WindowsAppSDK-Setup.h",
    "Microsoft.WindowsAppRuntime.Release.Net.dll.h"
)
foreach ($header in $additionalHeaders) {
    $windowsAppSdkPackageRoots |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter $header } |
        Select-Object -First 1 |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $includeRoot -Force }
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

    $windowsAppSdkPackageRoots |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter "Microsoft.WindowsAppRuntime.Bootstrap.dll" } |
        ForEach-Object { Copy-ArchitectureFile -File $_ -SdkRoot $sdkRoot -SubDirectory "bin" }
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