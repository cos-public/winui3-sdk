# Minimal CMake-consumable WinUI 3 SDK snapshot

The WinUI3 related crap from NuGet packages repacked as a bunch of headers, dynamic libraries, metadata and cmake config file to consume this.

## Rationale

C++/WinRT projection headers are generated deterministically from `.winmd` metadata. If the Windows App SDK package version and C++/WinRT tool version are pinned, this repository can generate those headers once in CI and publish them as a simple SDK artifact.

The artifact includes the Windows App Runtime bootstrap import library plus the native runtime DLLs discovered in the pinned Windows App SDK NuGet package graph. Consumers can deploy the appropriate `bin/<arch>` DLLs next to their executable, but should still verify Microsoft Windows App SDK redistribution and deployment requirements before publishing broadly.

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
    microsoft.ui.xaml.window.h
    microsoft.ui.xaml.media.dxinterop.h
    Microsoft.UI.Interop.h
    ...                              # all flat headers from the App SDK package include dirs
  lib/
    x64/Microsoft.WindowsAppRuntime.Bootstrap.lib
    arm64/Microsoft.WindowsAppRuntime.Bootstrap.lib
    x86/Microsoft.WindowsAppRuntime.Bootstrap.lib
  bin/
    x64/
      *.dll
      resources.pri              # WinUI control/theme resource index, auto-loaded by MRT
      Microsoft.UI.Xaml/Assets/  # theme asset files referenced by path
    arm64/ ...
    x86/ ...
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
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Markup;

// Built without the XAML compiler, so the App supplies XAML type metadata itself
// by implementing IXamlMetadataProvider (forwarded to the WinUI controls
// provider). Without this, merging XamlControlsResources throws 0x80004005.
// See "Runtime nuances" below.
struct App : ApplicationT<App, IXamlMetadataProvider>
{
    Window window{ nullptr };
    XamlTypeInfo::XamlControlsXamlMetaDataProvider provider;

    IXamlType GetXamlType(Windows::UI::Xaml::Interop::TypeName const& type) { return provider.GetXamlType(type); }
    IXamlType GetXamlType(hstring const& fullName) { return provider.GetXamlType(fullName); }
    com_array<XmlnsDefinition> GetXmlnsDefinitions() { return provider.GetXmlnsDefinitions(); }

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

## Runtime nuances (unpackaged, no-XAML WinUI 3)

A packaged WinUI 3 app, or one built through the XAML compiler and MSBuild, gets
two things for free that this no-compiler/unpackaged style must arrange by hand.
Both were needed before a window would appear; each fails in a confusing way.

### 1. The App must implement `IXamlMetadataProvider`

WinUI's control styles and theme brushes are authored in XAML and shipped as
compiled XBF inside the framework. Loading them needs XAML *type metadata* — a
map from XAML type names to activatable WinRT types. The XAML compiler normally
generates that (the `XamlTypeInfo` provider) and wires it into your `App`. With
no XAML compiler you must supply it yourself:

- derive from `ApplicationT<App, IXamlMetadataProvider>`;
- hold a `Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider`;
- forward `GetXamlType` (the `TypeName` and `hstring` overloads) and
  `GetXmlnsDefinitions` to it.

Headers: `winrt/Microsoft.UI.Xaml.Markup.h`,
`winrt/Microsoft.UI.Xaml.XamlTypeInfo.h`, and `winrt/Windows.UI.Xaml.Interop.h`
(for `TypeName`).

Symptom when missing: constructing/merging `XamlControlsResources` throws
`0x80004005` — typically surfaced as
`Cannot find a resource with the given key: AcrylicBackgroundFillColorDefaultBrush`.
The resource data is present; the parser just can't resolve the theme dictionary
types without the provider.

### 2. A `resources.pri` (plus theme assets) must sit next to the exe

An unpackaged process has no package identity, so WinUI's MRT-based resource
loader cannot reach the framework package's resources through the package graph.
Instead it auto-loads a file literally named `resources.pri` from the executable's
own folder. This snapshot deploys, in `bin/<arch>`:

- `resources.pri` — a copy of `Microsoft.UI.Xaml.Controls.pri`, the WinUI
  control/theme resource index (it embeds the `themeresources`/`generic` XBF).
  It is the primary resource map that `ms-appx:///Microsoft.UI.Xaml/...` URIs
  resolve against.
- `Microsoft.UI.Xaml/Assets/` — a few real files the theme references *by path*
  (for example `NoiseAsset_256x256_PNG.png`), so the folder layout must be
  preserved relative to the exe.

Because these live in `bin/<arch>`, copying that directory next to your
executable — which you already do for the runtime DLLs — satisfies both. No
`makepri` step is required in the consuming project.

Symptom when missing: `Cannot locate resource from`
`'ms-appx:///Microsoft.UI.Xaml/Themes/themeresources.xaml'` and no window.

### Why the loose per-component PRIs are not enough

The NuGet package graph also contains `Microsoft.UI.pri`,
`Microsoft.WindowsAppRuntime.pri`, and similar. WinUI does not auto-load those by
name, so deploying them verbatim does nothing — only the file named
`resources.pri` is loaded as the main resource map. That is why this snapshot
renames the WinUI controls index to `resources.pri` rather than shipping the
component PRIs as-is.

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
   - `include/microsoft.ui.xaml.window.h`
   - `lib/<arch>/Microsoft.WindowsAppRuntime.Bootstrap.lib`
   - `bin/<arch>/*.dll`
   - `cmake/WinUI3SDKConfig.cmake`
6. Test a small programmatic no-XAML app against the artifact.
7. Create/push a release tag after validation if you want a GitHub Release asset.

Files to edit when maintaining behavior:

- `scripts/Build-WinUI3SDK.ps1` — package download, metadata discovery, header/lib collection, zip creation.
- `cmake/WinUI3SDKConfig.cmake` — consumer-facing CMake imported target.
- `.github/workflows/build-sdk.yml` — pinned package versions, CI triggers, artifact/release publishing.
