# Check a built Windows bundle before it is published.
#
# Two things go wrong between "the build succeeded" and "the app works", and
# neither shows up in a file listing:
#
# 1. The bundle carries a stock Flutter engine. The video is a child HWND
#    inside the Flutter view and only the patched engine presents the UI above
#    it, so a stock engine ships a player whose controls are invisible --
#    present and clickable, but painted under the video. That shipped four
#    times (v2.30.1 through v2.33.0) with every check passing. Comparing the
#    bundled flutter_windows.dll against the engine in the SDK cache the build
#    actually used is what catches it.
#
# 2. The app cannot start. A missing MSVC runtime, an ABI-mismatched engine or
#    a broken native dependency all build cleanly and die on launch. Running
#    the thing for a few seconds in a scratch portable folder catches that,
#    and the folder it writes proves Dart ran, path_provider resolved and the
#    database opened.
#
# Exits non-zero on any failure; the caller is expected not to publish.
param(
    [Parameter(Mandatory = $true)][string]$BundleDir,
    # SHA256 of the engine DLL in the SDK cache this build used. Omit to skip
    # the engine check (a local build that deliberately uses stock).
    [string]$ExpectedEngineSha,
    [int]$SmokeSeconds = 25
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BundleDir -PathType Container)) {
    throw "bundle directory does not exist: $BundleDir"
}
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path

$required = @(
    'bask.exe'
    'flutter_windows.dll'
    'libmpv-2.dll'
    'sqlite3.dll'
    'data\app.so'
    'data\icudtl.dat'
    # Bundled by InstallRequiredSystemLibraries. Without it the app dies at
    # startup on any machine whose system redist is older than the toolset.
    'msvcp140.dll'
    'vcruntime140.dll'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $bundle $_)) })
if ($missing.Count -gt 0) {
    throw "bundle is missing: $($missing -join ', ')"
}

$engineDll = Join-Path $bundle 'flutter_windows.dll'
if ($ExpectedEngineSha) {
    $actual = (Get-FileHash -LiteralPath $engineDll -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedEngineSha.ToUpperInvariant()) {
        throw ("bundled flutter_windows.dll is not the engine this build installed " +
            "(bundle $actual, expected $($ExpectedEngineSha.ToUpperInvariant())) -- " +
            'a stock engine here means a player with invisible controls')
    }
    Write-Host "engine matches the installed patched engine ($actual)"
} else {
    Write-Host 'engine check skipped (no expected hash supplied)'
}

# Smoke run from a copy, in portable mode: the scratch folder is the only
# place it can write, so this cannot touch a real install's account or
# downloads, and whatever appears there is evidence the app got that far.
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("bask-smoke-" + [guid]::NewGuid().ToString('N'))
try {
    Copy-Item -LiteralPath $bundle -Destination $scratch -Recurse
    Set-Content -LiteralPath (Join-Path $scratch 'portable.txt') -Value 'portable' -Encoding ascii

    $exe = Join-Path $scratch 'bask.exe'
    $proc = Start-Process -FilePath $exe -WorkingDirectory $scratch -PassThru
    Write-Host "launched $exe (pid $($proc.Id)); watching for $SmokeSeconds seconds"

    $deadline = (Get-Date).AddSeconds($SmokeSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if ($proc.HasExited) {
            throw "the app exited $([int]((Get-Date) - $proc.StartTime).TotalSeconds)s after launch with code $($proc.ExitCode)"
        }
    }

    # Written by PortableMode plus the stores that follow it. Their absence
    # means Dart never got as far as resolving a path.
    $data = Join-Path $scratch 'bask-data'
    if (-not (Test-Path -LiteralPath $data)) {
        throw 'the app started but never wrote its portable data folder'
    }
    $support = Join-Path $data 'support'
    if (-not (Test-Path -LiteralPath $support)) {
        throw 'the app wrote no application support folder; the database never opened'
    }
    $wrote = @(Get-ChildItem -LiteralPath $data -Recurse -File -Force)
    Write-Host "stayed up for ${SmokeSeconds}s and wrote $($wrote.Count) file(s) under bask-data"
    if ($wrote.Count -eq 0) {
        throw 'the portable data folder is empty; nothing initialized'
    }
} finally {
    Get-Process -Name 'plezy' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'bundle verified'
