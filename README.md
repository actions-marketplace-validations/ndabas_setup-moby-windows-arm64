# setup-moby-windows-arm64

Windows ARM64 builds of the [moby](https://github.com/moby/moby) Docker engine (`dockerd.exe`), plus a GitHub
Action to install and start them on Windows ARM64 runners such as `windows-11-arm`.

## Using the action

```yaml
jobs:
  build:
    runs-on: windows-11-arm
    steps:
      - uses: ndabas/setup-moby-windows-arm64@v1
      - run: docker run --rm mcr.microsoft.com/windows/nanoserver:ltsc2025-arm64 cmd /c ver
```

The action downloads a release from this repository, adds `docker.exe` and `dockerd.exe` to `PATH`, registers
`dockerd` as a Windows service, starts it, and waits until the daemon is ready. If `docker` is already on `PATH`,
the action does nothing by default and adds a notice annotation to the workflow run.

The `v1` tag tracks the latest compatible version of the action. It is separate from the `docker-v*` release tags,
which name the moby builds that the `version` input installs.

### Inputs

| Input                     | Default                        | Description                                                                                                                      |
| ------------------------- | ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `version`                 | `latest`                       | Release to install: `latest` (the highest `docker-v*` release), or a moby release tag such as `docker-v29.9.0` (`29.9.0` and `v29.9.0` are also accepted). |
| `repository`              | the action's repository        | Repository to download the build from.                                                                                           |
| `binaries-path`           |                                | Use `docker.exe` and `dockerd.exe` from this local directory instead of downloading a release.                                   |
| `skip-if-present`         | `true`                         | If `docker` is already on `PATH`, use it and do nothing.                                                                         |
| `start-daemon`            | `true`                         | Register `dockerd` as a Windows service, start it and wait until it is ready.                                                    |
| `dockerd-args`            | `--exec-opt isolation=process` | Extra arguments passed to `dockerd`.                                                                                             |
| `service-name`            | `docker`                       | Name of the Windows service to register `dockerd` as.                                                                            |
| `timeout-seconds`         | `180`                          | How long to wait for `dockerd` to become ready.                                                                                  |
| `token`                   | `${{ github.token }}`          | GitHub token used to query and download releases.                                                                                |
| `platform-check-severity` | `fatal`                        | What to do on a runner that isn't Windows ARM64: `fatal` fails the step, `warn` logs a warning and skips the rest of the action. |

For example, to use the action in a job that also runs on other platforms:

```yaml
      - uses: ndabas/setup-moby-windows-arm64@v1
        with:
          platform-check-severity: warn
```

When the action is skipped this way, all of its outputs are empty.

### Outputs

| Output         | Description                                                                                                 |
| -------------- | ----------------------------------------------------------------------------------------------------------- |
| `version`      | The release tag that was installed (`local` when `binaries-path` is used, empty if a pre-installed docker was used). |
| `docker-path`  | Directory containing `docker.exe` and `dockerd.exe`.                                                        |
| `preinstalled` | `true` if an existing `docker` on `PATH` was used and nothing was installed.                               |

## Installing on your own machine

[Install-Moby.ps1](Install-Moby.ps1) installs a release on a Windows ARM64 machine. From an elevated PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ndabas/setup-moby-windows-arm64/master/Install-Moby.ps1)))
```

It downloads the latest `docker-v*` release (or `-Version docker-v29.9.0`, or a local build with `-SourcePath`), verifies its
checksum, and installs `docker.exe` and `dockerd.exe` to `C:\Program Files\moby`, which it adds to the machine
`PATH`. It then writes `C:\ProgramData\docker\config\daemon.json`, registers `dockerd` as the `docker` service, and
starts it. If the Windows Containers feature isn't enabled, the script enables it and asks you to restart.
Running the script again upgrades or downgrades the installation.

By default, `daemon.json` gives the current user access to the `docker_engine` pipe through the `group` setting,
so `docker` works from non-elevated shells. It also sets `exec-opts` to `isolation=process`. Other options:

| Parameter            | Description                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------- |
| `-Principal`         | Users and/or groups to grant pipe access to, instead of the current user (`@()` to skip).         |
| `-Isolation`         | `process` (default) or `hyperv` (`''` to leave unchanged).                                         |
| `-StorageSize`       | Sets `storage-opts` `size=` (e.g. `300GB`); the default 20 GB sandbox is small for large images.  |
| `-DataRoot`          | Stores images and containers elsewhere (e.g. `D:\docker`, must be NTFS).                          |
| `-DefenderExclusion` | Excludes the data root from Microsoft Defender scanning, which speeds up large layer commits.     |
| `-InstallPath`       | Where to install the binaries.                                                                    |
| `-NoPath`, `-NoStart` | Don't add the binaries to the machine `PATH` / don't start the service.                          |
| `-Force`             | Replace a `docker` service that runs a `dockerd.exe` from another location.                       |

For example:

```powershell
.\Install-Moby.ps1 -Version docker-v29.9.0 -StorageSize 300GB -DataRoot D:\docker -DefenderExclusion
```

See `Get-Help .\Install-Moby.ps1 -Full` for details.

## Releases

The [Build and release](.github/workflows/release.yml) workflow runs weekly and can be triggered manually. It looks
up the latest moby release, and if this repository doesn't have a release with the same tag yet, it:

1. builds `dockerd.exe` from that tag with `hack/make.ps1 -Client -Daemon` on a `windows-11-arm` runner,
2. tests the build with the [Test](.github/workflows/test.yml) workflow, which sets up the daemon with both this
   action and `Install-Moby.ps1`, then runs and builds containers, and
3. publishes `docker-windows-arm64.zip` and its SHA-256 checksum as a release tagged with the moby tag, e.g.
   `docker-v29.9.0`.

To build a specific moby tag, run the workflow manually and set the `moby-tag` input.

The `docker.exe` client and `docker-buildx.exe` in the zip are the x64 binaries that `hack/make.ps1 -Client`
downloads; they run under emulation on Windows ARM64.

## Development

The [Lint](.github/workflows/lint.yml) workflow runs on pushes and pull requests:

- [actionlint](https://github.com/rhysd/actionlint) checks the workflows and `action.yml`, using shellcheck for
  bash steps.
- [Invoke-PSScriptAnalyzer.ps1](.github/scripts/Invoke-PSScriptAnalyzer.ps1) runs PSScriptAnalyzer, with
  [PSScriptAnalyzerSettings.psd1](PSScriptAnalyzerSettings.psd1), on the PowerShell scripts and on the `pwsh`
  steps embedded in `action.yml` and the workflows. It needs [yq](https://github.com/mikefarah/yq) on `PATH`.
