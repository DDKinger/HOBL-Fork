# .NET Aspire Build Workload

Builds the [.NET Aspire](https://github.com/dotnet/aspire) cloud-app orchestration stack from
source (tag `v9.4.2`). It restores, cleans, then performs a no-restore rebuild of
`Aspire.slnx` and reports build time — a large managed (.NET / MSBuild) build workload.

## What HOBL sets up (from `net_aspire_resources/net_aspire_prep.ps1`)

- winget: stable .NET SDK 11.0.100, .NET SDK 8, Git
- Clones `dotnet/aspire` @ `v9.4.2` to `<drive>\aspire`
- Pins `global.json`'s `sdk.version` and `tools.dotnet` to `11.0.100`, disables
  prerelease SDK selection and roll-forward, and keeps the Aspire source workload unchanged.

SDK `11.0.100` is the latest stable SDK verified against
[Microsoft release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json)
on November 22, 2026. macOS prep applies the same pin before `build.sh` lets
Arcade install the SDK into the Aspire repository's `.dotnet` directory.
Existing DUTs rerun prep for this SDK upgrade (Windows prep version `10`,
macOS prep version `12`).

## Run it standalone (Windows)

```powershell
winget install --id Microsoft.DotNet.SDK.11 --source winget --version 11.0.100
winget install --id Microsoft.DotNet.SDK.8 --source winget
winget install --id Git.Git --source winget

git clone https://github.com/dotnet/aspire.git
cd aspire
git checkout v9.4.2

$config = Get-Content .\global.json -Raw | ConvertFrom-Json
$config.sdk.version = "11.0.100"
$config.sdk.rollForward = "disable"
$config.sdk.allowPrerelease = $false
$config.tools.dotnet = "11.0.100"
$config | ConvertTo-Json -Depth 100 | Set-Content .\global.json -Encoding utf8

# Timed workload
dotnet restore Aspire.slnx
dotnet clean Aspire.slnx
dotnet build Aspire.slnx --no-restore
```

## Optional build parameters (Windows and macOS)

All options preserve the original workload by default and affect only the timed
build, not prep, clean, or restore:

| Parameter | Default | Effect |
| --- | --- | --- |
| `binlog` | `0` | Set to `1` to collect a separate MSBuild binary log for each build loop. |
| `skip_playwright_browser_install` | `0` | Set to `1` to add `-p:InstallBrowsersForPlaywright=false`. Playwright packages and projects are still built. |
| `max_cpu_count` | `0` | Set to a positive integer to add `-m:<value>`. `0` keeps the original default, not single-threaded execution. |
| `direct_schema_exec` (Windows only) | `0` | Set to `1` to launch each configuration schema generator directly from MSBuild, without `cmd.exe`. Schema generation and validation still run. |
| `protobuf_tools_cpu` (Windows only) | `default` | Set to `x86` or `x64` for the bundled tools, or `arm64` for separately staged native Windows ARM64 tools. `default` keeps Grpc.Tools auto-selection. |

Set the options in the corresponding profile section:

```ini
[net_aspire]
binlog=0
skip_playwright_browser_install=0
max_cpu_count=0
protobuf_tools_cpu=default

[mac_net_aspire]
binlog=0
skip_playwright_browser_install=0
max_cpu_count=0
```

Alternatively, append the corresponding overrides to the HOBL command:

```powershell
# Windows experiment A: only skip repeated browser preparation
net_aspire:skip_playwright_browser_install=1 net_aspire:max_cpu_count=0
# Windows experiment B: original workload, only change parallelism
net_aspire:skip_playwright_browser_install=0 net_aspire:max_cpu_count=12
# Windows codegen A/B: append one of these to otherwise identical commands
net_aspire:protobuf_tools_cpu=x86
net_aspire:protobuf_tools_cpu=x64
# Native Windows ARM64, after staging both tools on the DUT
net_aspire:protobuf_tools_cpu=arm64

# macOS experiment A
mac_net_aspire:skip_playwright_browser_install=1 mac_net_aspire:max_cpu_count=0
# macOS experiment B
mac_net_aspire:skip_playwright_browser_install=0 mac_net_aspire:max_cpu_count=12
```

Both controls can be combined with `net_aspire:binlog=1` on Windows or
`mac_net_aspire:binlog=1` on macOS. Keep binlog, power mode, and other settings
identical when comparing experiments; logging overhead is included in build time.

Binary logs are collected with the scenario results:
`net_aspire_build_<timestamp>.binlog` in `<drive>\hobl_data` on Windows and
`mac_net_aspire_build_<timestamp>_<pid>.binlog` in `/Users/Shared/hobl_data` on macOS.
For DUTs already prepared with this SDK version, enabling an option refreshes only
the run script; toggling the options does not require another prep version bump.

Standalone Windows runs accept `-binlog`, `-skipPlaywrightBrowserInstall`, and
`-maxCpuCount 12` on `net_aspire_run.ps1`. For the Windows SchemaGenerator A/B,
use `net_aspire:direct_schema_exec=0` (original) and `net_aspire:direct_schema_exec=1`
(standalone: `-directSchemaExec`). The option imports an experiment target during
the timed build only, without modifying the Aspire checkout or requiring re-prep.

Standalone Windows codegen runs accept `-protobufToolsCpu x86` or
`-protobufToolsCpu x64`. This switches tools from the current Grpc.Tools package,
not the .NET SDK, and does not modify machine or user environment variables.
An explicit protoc/plugin path override can take precedence over packaged tool
selection. Before benchmarking, use `binlog=1` to confirm both actual tool paths
contain `windows_x86` or `windows_x64`, respectively, and that generated outputs
are equivalent. Keep the SDK, Grpc.Tools version, inputs, and other options fixed;
use `binlog=0` for both groups when comparing build time without logging overhead.
On Windows ARM64, both x86 and x64 tools are emulated, not native ARM64 tools.

For `net_aspire:protobuf_tools_cpu=arm64` (standalone: `-protobufToolsCpu arm64`),
extract the same-version Windows ARM64 codegen bundle so that `protoc.exe` and
`grpc_csharp_plugin.exe` are directly under
`<drive>\hobl_bin\grpc-tools-arm64\2.72.0` on the DUT. Use the same drive as the
scenario script. The bundle must be built from the source pinned by Grpc.Tools
2.72.0; use this experimental mode with a workload that restores that version.
The run script rejects missing or non-ARM64 executables before clean/restore
and passes their absolute paths only to the timed build. It does not change
the NuGet cache, `global.json`, or the system environment. No re-prep is needed.
Verify both executable paths in a diagnostic binlog and compare the generated
C# files to the bundled-tool baseline before measuring with binlog disabled.

macOS runs accept `--binlog`,
`--skip-playwright-browser-install`, and `--max-cpu-count 12` on
`mac_net_aspire_run.sh`. Selected build arguments are recorded in the run log.

## Notes

- On ARM64, HOBL points `DOTNET_INSTALL_DIR` at the system dotnet to avoid pulling an
  x64-only legacy runtime. If `dotnet restore` complains about an old runtime, set
  `$env:DOTNET_INSTALL_DIR="C:\Program Files\dotnet"`.
- Aspire restores only from Microsoft/dnceng NuGet feeds. Default: 4 loops.
