[CmdletBinding()]
param(
    [ValidateSet('Fast', 'Release')]
    [string]$Mode = 'Fast',
    [string]$OutputDirectory = 'teleDB-test-package'
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$tauriManifest = Join-Path $repositoryRoot 'src-tauri\Cargo.toml'
$fastTargetDirectory = Join-Path $repositoryRoot 'target\teledb-fast'
$outputDirectory = Join-Path $repositoryRoot $OutputDirectory
$updaterOverride = '{"bundle":{"createUpdaterArtifacts":false}}'

function Restore-EnvironmentVariable {
    param(
        [string]$Name,
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item "Env:$Name" $Value
    }
}

function Get-PackageArtifact {
    param([string]$TargetDirectory)

    $bundleDirectory = Join-Path $TargetDirectory 'release\bundle\nsis'
    $artifact = Get-ChildItem -LiteralPath $bundleDirectory -Filter '*-setup.exe' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $artifact) {
        throw "NSIS installer was not produced in $bundleDirectory"
    }

    return $artifact
}

Push-Location $repositoryRoot

$originalCargoHome = $env:CARGO_HOME
$originalTargetDirectory = $env:CARGO_TARGET_DIR
$originalReleaseLto = $env:CARGO_PROFILE_RELEASE_LTO
$originalReleaseCodegenUnits = $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS
$manifestBackup = $null

try {
    # Reuse the local registry cache created by the first Windows build when available.
    $localCargoHome = Join-Path $repositoryRoot '.cargo-build'
    if (Test-Path -LiteralPath $localCargoHome) {
        $env:CARGO_HOME = $localCargoHome
    }

    if ($Mode -eq 'Fast') {
        $manifestBackup = Join-Path $env:TEMP "dbx-tauri-manifest-$PID.toml"
        Copy-Item -LiteralPath $tauriManifest -Destination $manifestBackup -Force

        $manifest = [System.IO.File]::ReadAllText($tauriManifest)
        $manifest = [regex]::Replace(
            $manifest,
            '(?m)^crate-type\s*=\s*\[[^\r\n]+\]$',
            'crate-type = ["rlib"]'
        )
        $manifest = [regex]::Replace(
            $manifest,
            '(?m)^default\s*=\s*\[[^\r\n]+\]$',
            'default = ["duckdb-sidecar", "mq-admin", "system-fonts"]',
            1
        )
        [System.IO.File]::WriteAllText(
            $tauriManifest,
            $manifest,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Use a dedicated cache and lighter release settings for repeated TeleDB verification builds.
        $env:CARGO_TARGET_DIR = $fastTargetDirectory
        $env:CARGO_PROFILE_RELEASE_LTO = 'false'
        $env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = '16'
    }

    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    Write-Host "Building $Mode package..."
    & pnpm exec tauri build --bundles nsis --config $updaterOverride
    if ($LASTEXITCODE -ne 0) {
        throw "Tauri build failed with exit code $LASTEXITCODE"
    }

    $targetDirectory = if ($Mode -eq 'Fast') { $fastTargetDirectory } else { Join-Path $repositoryRoot 'target' }
    $artifact = Get-PackageArtifact -TargetDirectory $targetDirectory
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destination = Join-Path $outputDirectory "DBX-$($Mode.ToLowerInvariant())-$timestamp-setup.exe"
    Copy-Item -LiteralPath $artifact.FullName -Destination $destination -Force

    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    Write-Host ''
    Write-Host "Package: $destination"
    Write-Host "SHA256 : $hash"
    if ($Mode -eq 'Fast') {
        Write-Host 'Note   : Fast package excludes sqlite-sqlcipher; TeleDB/MySQL functionality is included.'
    }
}
finally {
    if ($null -ne $manifestBackup -and (Test-Path -LiteralPath $manifestBackup)) {
        [System.IO.File]::Copy($manifestBackup, $tauriManifest, $true)
        Remove-Item -LiteralPath $manifestBackup -Force
    }

    Restore-EnvironmentVariable -Name 'CARGO_HOME' -Value $originalCargoHome
    Restore-EnvironmentVariable -Name 'CARGO_TARGET_DIR' -Value $originalTargetDirectory
    Restore-EnvironmentVariable -Name 'CARGO_PROFILE_RELEASE_LTO' -Value $originalReleaseLto
    Restore-EnvironmentVariable -Name 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS' -Value $originalReleaseCodegenUnits
    Pop-Location
}
