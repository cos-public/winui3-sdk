# Minimal CMake-consumable WinUI 3 SDK snapshot

This repository builds a small vendorable SDK zip for using **WinUI 3 / Windows App SDK** from a normal CMake C++ project.

The main target is an unpackaged, no-XAML, programmatic WinUI 3 application: for example, a native Windows GUI shell around a custom Vulkan image viewer. The consuming project should not need to run NuGet restore, `cppwinrt.exe`, MIDL, XAML compilation, PRI generation, or MSBuild WinUI targets.

## Rationale

C++/WinRT projection headers are generated deterministically from `.winmd` metadata. If the Windows App SDK package version and C++/WinRT tool version are pinned, this repository can generate those headers once in CI and publish them as a simple SDK artifact.

The result is not a new runtime and it does not make WinUI 3 a C library. It only packages the generated headers, public Windows App SDK headers, metadata, import libraries, and a CMake package config.

The artifact includes the Windows App Runtime bootstrap import library and bootstrap DLL. Consumers still need the Windows App SDK runtime installed or deployed according to Microsoft guidance.

## Artifact layout

The workflow produces a zip named like:

```text
winui3-sdk-<windows-app-sdk-version>-cppwinrt-<cppwinrt-version>.zip
```

Inside:

```text
WinUI3SDK/
  include/
    winrt/
      base.h
      Microsoft.UI.Xaml.h
      Microsoft.UI.Xaml.Controls.h
      ...
    MddBootstrap.h
    WindowsAppSDK-VersionInfo.h
  lib/
    x64/Microsoft.WindowsAppRuntime.Bootstrap.lib
    arm64/Microsoft.WindowsAppRuntime.Bootstrap.lib
    x86/Microsoft.WindowsAppRuntime.Bootstrap.lib
  bin/
    x64/Microsoft.WindowsAppRuntime.Bootstrap.dll
    arm64/Microsoft.WindowsAppRuntime.Bootstrap.dll
    x86/Microsoft.WindowsAppRuntime.Bootstrap.dll
  winmd/
    *.winmd
  cmake/
    WinUI3SDKConfig.cmake
  VERSION.txt
```

`WinUI3SDKConfig.cmake` is maintained as a normal source file at `cmake/WinUI3SDKConfig.cmake` and copied into the artifact. It is deliberately not embedded in the build script.

## Build the SDK

Package versions are pinned in `.github/workflows/build-sdk.yml`:

```yaml
env:
  WINDOWS_APP_SDK_VERSION: 2.2.0
  CPPWINRT_VERSION: 3.0.260520.1
```

The workflow runs on every push. To build a new package version, edit those two values, commit, and push. The action will create and upload the zip artifact.

Tag pushes matching `v*` also attach the zip to a GitHub Release.

Local build:

```powershell
.\scripts\Build-WinUI3SDK.ps1 `
  -WindowsAppSDKVersion 2.2.0 `
  -CppWinRTVersion 3.0.260520.1 `
  -IncludeRuntimeDlls
```

The local script still requires explicit version arguments. The GitHub workflow supplies them from its pinned `env:` block.

## Use from a CMake application

Unpack the zip and point CMake at the unpacked `WinUI3SDK` directory:

```powershell
cmake -S . -B build -G Ninja -DCMAKE_PREFIX_PATH=C:\path\to\WinUI3SDK
```

Example `CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.24)
project(MyWinUIApp LANGUAGES CXX)

find_package(WinUI3SDK CONFIG REQUIRED)

add_executable(my_app WIN32
    src/main.cpp
)

target_compile_features(my_app PRIVATE cxx_std_20)
target_link_libraries(my_app PRIVATE WinUI3SDK::WinUI3SDK)
```

The first intended style of application is:

- unpackaged Win32 executable
- C++20
- C++/WinRT
- programmatic WinUI 3 UI creation
- no `.xaml`
- no custom `.idl` components
- explicit Windows App SDK bootstrap initialization

Minimal app skeleton:

```cpp
#include <windows.h>
#undef GetCurrentTime

#include <MddBootstrap.h>
#include <WindowsAppSDK-VersionInfo.h>

#include <winrt/base.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;

struct App : ApplicationT<App>
{
    Window window{ nullptr };

    void OnLaunched(LaunchActivatedEventArgs const&)
    {
        Resources().MergedDictionaries().Append(XamlControlsResources());

        window = Window();

        Grid root;
        Button button;
        button.Content(box_value(L"Hello from programmatic WinUI 3"));
        root.Children().Append(button);

        window.Content(root);
        window.Activate();
    }
};

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    winrt::init_apartment(winrt::apartment_type::single_threaded);

    HRESULT hr = MddBootstrapInitialize(
        WINDOWSAPPSDK_RELEASE_MAJORMINOR,
        WINDOWSAPPSDK_RELEASE_VERSION_TAG_W,
        { WINDOWSAPPSDK_RUNTIME_VERSION_UINT64 }
    );
    if (FAILED(hr))
        return static_cast<int>(hr);

    Application::Start([](auto&&) { make<App>(); });

    MddBootstrapShutdown();
    return 0;
}
```

## Maintaining this repository

To update package versions:

1. Choose the exact `Microsoft.WindowsAppSDK` NuGet version.
2. Choose the exact `Microsoft.Windows.CppWinRT` NuGet version.
3. Edit `.github/workflows/build-sdk.yml`:
   ```yaml
   env:
     WINDOWS_APP_SDK_VERSION: <windows-app-sdk-version>
     CPPWINRT_VERSION: <cppwinrt-version>
   ```
4. Commit and push. The workflow runs on push and uploads the package zip.
5. Inspect the produced artifact layout, especially:
   - `include/winrt/`
   - `include/MddBootstrap.h`
   - `include/WindowsAppSDK-VersionInfo.h`
   - `lib/<arch>/Microsoft.WindowsAppRuntime.Bootstrap.lib`
   - `bin/<arch>/Microsoft.WindowsAppRuntime.Bootstrap.dll`
   - `cmake/WinUI3SDKConfig.cmake`
6. Test a small programmatic no-XAML app against the artifact.
7. Create/push a release tag after validation if you want a GitHub Release asset.

Files to edit when maintaining behavior:

- `scripts/Build-WinUI3SDK.ps1` — package download, metadata discovery, header/lib collection, zip creation.
- `cmake/WinUI3SDKConfig.cmake` — consumer-facing CMake imported target.
- `.github/workflows/build-sdk.yml` — pinned package versions, CI triggers, artifact/release publishing.

The workflow packages the bootstrap DLL. Verify Microsoft Windows App SDK redistribution and deployment requirements before publishing the artifact broadly.