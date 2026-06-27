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

function Copy-FirstRequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $file = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter | Select-Object -First 1
    if (!$file) {
        throw "Required file '$Filter' was not found under '$Root'."
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $Destination -Force
    Write-Host "Copied $($file.FullName) -> $Destination"
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

function Get-WindowsSdkWinmdDirectory {
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\UnionMetadata"
    if (!(Test-Path $kitsRoot)) {
        return $null
    }

    $windowsWinmd = Get-ChildItem -LiteralPath $kitsRoot -Recurse -File -Filter "Windows.winmd" |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if (!$windowsWinmd) {
        return $null
    }

    return $windowsWinmd.Directory.FullName
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

$cppwinrt = Get-ChildItem -LiteralPath $cppWinRTRoot -Recurse -File -Filter cppwinrt.exe | Select-Object -First 1
if (!$cppwinrt) {
    throw "cppwinrt.exe was not found under '$cppWinRTRoot'."
}

New-Item -ItemType Directory -Force -Path $includeRoot, $winmdOut, $cmakeOut | Out-Null

Write-Host "Copying baseline C++/WinRT headers..."
$cppWinRTIncludeDirs = @(Get-ChildItem -LiteralPath $cppWinRTRoot -Recurse -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "winrt\base.h") })
if (!$cppWinRTIncludeDirs) {
    throw "Could not find C++/WinRT include directory containing winrt/base.h."
}
Copy-Item -LiteralPath (Join-Path $cppWinRTIncludeDirs[0].FullName "winrt") -Destination $includeRoot -Recurse -Force

Write-Host "Finding Windows App SDK metadata..."
$winmdFiles = @(Get-ChildItem -LiteralPath $windowsAppSdkRoot -Recurse -File -Filter *.winmd |
    Where-Object { $_.FullName -notmatch '\\ref\\net' } |
    Sort-Object FullName)
if (!$winmdFiles) {
    throw "No .winmd files were found under '$windowsAppSdkRoot'."
}

$winmdDirs = @($winmdFiles |
    ForEach-Object { $_.Directory.FullName } |
    Sort-Object -Unique)

$windowsSdkWinmdDirectory = Get-WindowsSdkWinmdDirectory
if ($windowsSdkWinmdDirectory) {
    Write-Host "Windows SDK metadata directory: $windowsSdkWinmdDirectory"
    $winmdDirs = @($windowsSdkWinmdDirectory) + $winmdDirs
}
else {
    Write-Warning "Windows SDK Windows.winmd was not found. cppwinrt.exe may fail if Windows metadata cannot be resolved implicitly."
}

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

Write-Host "Copying Windows App SDK public headers..."
Copy-FirstRequiredFile -Root $windowsAppSdkRoot -Filter "MddBootstrap.h" -Destination $includeRoot
Copy-FirstRequiredFile -Root $windowsAppSdkRoot -Filter "WindowsAppSDK-VersionInfo.h" -Destination $includeRoot

$additionalHeaders = @(
    "MddBootstrapTest.h",
    "WindowsAppSDK-Setup.h",
    "Microsoft.WindowsAppRuntime.Release.Net.dll.h"
)
foreach ($header in $additionalHeaders) {
    Get-ChildItem -LiteralPath $windowsAppSdkRoot -Recurse -File -Filter $header |
        Select-Object -First 1 |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $includeRoot -Force }
}

Write-Host "Copying import libraries..."
foreach ($arch in @("x64", "arm64", "x86")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $sdkRoot "lib\$arch") | Out-Null
}

$bootstrapLibs = @(Get-ChildItem -LiteralPath $windowsAppSdkRoot -Recurse -File -Filter "Microsoft.WindowsAppRuntime.Bootstrap.lib")
if (!$bootstrapLibs) {
    throw "Microsoft.WindowsAppRuntime.Bootstrap.lib was not found under '$windowsAppSdkRoot'."
}
foreach ($lib in $bootstrapLibs) {
    Copy-ArchitectureFile -File $lib -SdkRoot $sdkRoot -SubDirectory "lib"
}

if ($IncludeRuntimeDlls) {
    Write-Host "Including runtime DLLs. Verify Microsoft Windows App SDK redistribution and deployment requirements before publishing this artifact."
    foreach ($arch in @("x64", "arm64", "x86")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $sdkRoot "bin\$arch") | Out-Null
    }

    Get-ChildItem -LiteralPath $windowsAppSdkRoot -Recurse -File -Filter "Microsoft.WindowsAppRuntime.Bootstrap.dll" |
        ForEach-Object { Copy-ArchitectureFile -File $_ -SdkRoot $sdkRoot -SubDirectory "bin" }
}

Write-Host "Copying metadata..."
$seenWinmdNames = @{}
foreach ($winmd in $winmdFiles) {
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