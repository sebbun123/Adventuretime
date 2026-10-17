param(
    # Folder holding the files you are about to publish (must contain init.lua)
    [string]$SourceDir = ".",
    # Files to publish, relative to SourceDir. Every modules\*.lua is added on its own.
    [string[]]$Files = @("init.lua"),
    # Files that should be REMOVED from an existing install
    [string[]]$Delete = @()
)

# Run this before uploading. Writing hashes by hand goes wrong on the first
# try and the failure looks like a corrupt download, so it is worth the
# fifteen lines to never do it by hand.

$ErrorActionPreference = 'Stop'

$initPath = Join-Path $SourceDir 'init.lua'
if (-not (Test-Path $initPath)) { throw "No init.lua in $SourceDir" }

$m = Select-String -Path $initPath -Pattern "BUILD_TAG\s*=\s*'([^']+)'" | Select-Object -First 1
if (-not $m) { throw "Could not find BUILD_TAG in init.lua" }
$build = $m.Matches[0].Groups[1].Value

# Every module in modules\ goes out with init.lua (1.22.0), so a new module can never be left out of an update.
$modDir = Join-Path $SourceDir 'modules'
if (Test-Path $modDir) {
    Get-ChildItem -Path $modDir -Filter '*.lua' | Sort-Object Name | ForEach-Object {
        $rel = 'modules/' + $_.Name
        if ($Files -notcontains $rel) { $Files += $rel }
    }
}

$lines = @()
$lines += "# AdventureTime manifest - generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$lines += "# Do not hand-edit the hashes; re-run make-manifest.ps1 instead."
$lines += "build`t$build"

foreach ($f in $Files) {
    $p = Join-Path $SourceDir $f
    if (-not (Test-Path $p)) { throw "Listed file not found: $p" }
    $sha = (Get-FileHash -Path $p -Algorithm SHA256).Hash.ToLower()
    $lines += "file`t$f`t$sha"
}

foreach ($d in $Delete) { $lines += "delete`t$d" }

$out = Join-Path $SourceDir 'manifest.txt'
$lines | Set-Content -Path $out -Encoding ASCII
Write-Host "Wrote $out for build $build" -ForegroundColor Green
$lines | ForEach-Object { Write-Host "  $_" }
