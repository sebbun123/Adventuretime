@echo off
setlocal
REM ===========================================================================
REM  AdventureTime updater - single file.
REM  Put this next to init.lua:  ...\MacroQuest\lua\AdventureTime\update.bat
REM  Edit BASEURL below, then double-click.
REM
REM  The PowerShell that does the work is at the bottom of this same file,
REM  after the LAST #PSSTART# marker. cmd never reaches it; PowerShell reads
REM  this file and runs that half. [-1] not [1]: the marker name also appears
REM  in these comments and in the command below, so only the final split is
REM  guaranteed to be the script body.
REM ===========================================================================

set "AT_BASEURL=https://raw.githubusercontent.com/sebbun123/Adventuretime/main"

REM  No argument = the repo root, where init.lua already lives.
REM  Pass a name to use a subfolder instead, e.g.  update.bat test
set "AT_CHANNEL=%~1"
set "AT_TARGET=%~dp0"

echo.
echo   AdventureTime updater
if "%AT_CHANNEL%"=="" (echo   source  : repo root) else (echo   source  : %AT_CHANNEL%)
echo   folder  : %AT_TARGET%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$b=[IO.File]::ReadAllText('%~f0'); iex (($b -split '#PSSTART#')[-1])"

:done
echo.
echo   ---- finished. Press any key to close. ----
pause >nul
endlocal
exit /b

#PSSTART#
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseUrl   = $env:AT_BASEURL
$Channel   = $env:AT_CHANNEL
$TargetDir = $env:AT_TARGET
# A blank channel means the repo root; a named one means a subfolder.
$root      = if ([string]::IsNullOrWhiteSpace($Channel)) { $BaseUrl } else { "$BaseUrl/$Channel" }
$stage     = Join-Path $env:TEMP ("at_update_" + [guid]::NewGuid().ToString('N'))

function Say($m, $c = 'Gray') { Write-Host "  $m" -ForegroundColor $c }

try {
    # ---- manifest ----------------------------------------------------------
    try {
        $manifestText = (Invoke-WebRequest -UseBasicParsing -Uri "$root/manifest.txt").Content
    } catch {
        Say "Could not read $root/manifest.txt" 'Red'
        Say $_.Exception.Message 'Red'
        return
    }

    $wantBuild = $null
    $files = @()
    foreach ($line in ($manifestText -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $p = $t -split '\s+'
        switch ($p[0]) {
            'build'  { $wantBuild = $p[1] }
            'file'   { $files += [pscustomobject]@{ Path = $p[1]; Sha = $p[2].ToLower() } }
            'delete' { $files += [pscustomobject]@{ Path = $p[1]; Sha = 'DELETE' } }
        }
    }
    if (-not $wantBuild)   { Say "Manifest has no build line - stopping." 'Red'; return }
    if ($files.Count -eq 0) { Say "Manifest lists no files - stopping." 'Red'; return }

    # The installed version is read out of init.lua itself, so it cannot drift
    # from the code it describes.
    $haveBuild = '(none)'
    $initPath  = Join-Path $TargetDir 'init.lua'
    if (Test-Path $initPath) {
        $m = Select-String -Path $initPath -Pattern "BUILD_TAG\s*=\s*'([^']+)'" | Select-Object -First 1
        if ($m) { $haveBuild = $m.Matches[0].Groups[1].Value }
    }

    Say "installed : $haveBuild"
    Say "available : $wantBuild"
    Say ""
    if ($haveBuild -eq $wantBuild) { Say "Already up to date." 'Green'; return }

    # ---- ALL OR NOTHING ----------------------------------------------------
    # Everything is downloaded and hash-checked before a single file in the
    # target folder is touched. A half-applied update is worse than an old one:
    # the failure looks like a logic bug rather than a bad download.
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $toWrite = @(); $toDelete = @()

    foreach ($f in $files) {
        if ($f.Sha -eq 'DELETE') { $toDelete += $f.Path; continue }
        $dst = Join-Path $stage $f.Path
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Say "fetching $($f.Path)"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$root/$($f.Path)" -OutFile $dst
        } catch {
            Say "FAILED to download $($f.Path) - nothing changed." 'Red'
            Say $_.Exception.Message 'Red'
            return
        }
        $got = (Get-FileHash -Path $dst -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $f.Sha) {
            Say "CHECKSUM MISMATCH on $($f.Path) - nothing changed." 'Red'
            Say "  expected $($f.Sha)" 'Red'
            Say "  got      $got" 'Red'
            return
        }
        $toWrite += $f.Path
    }

    # ---- back up, then swap ------------------------------------------------
    $backup = Join-Path $TargetDir ("backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null

    foreach ($rel in $toWrite) {
        $dst = Join-Path $TargetDir $rel
        if (Test-Path $dst) {
            $bk = Join-Path $backup $rel
            New-Item -ItemType Directory -Path (Split-Path $bk -Parent) -Force | Out-Null
            Copy-Item $dst $bk -Force
        }
        New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
        Copy-Item (Join-Path $stage $rel) $dst -Force
        Say "updated  $rel" 'Green'
    }
    foreach ($rel in $toDelete) {
        $dst = Join-Path $TargetDir $rel
        if (Test-Path $dst) {
            $bk = Join-Path $backup $rel
            New-Item -ItemType Directory -Path (Split-Path $bk -Parent) -Force | Out-Null
            Move-Item $dst $bk -Force
            Say "removed  $rel" 'Yellow'
        }
    }

    Say ""
    Say "Now on $wantBuild." 'Green'
    Say "Replaced files kept in: $backup"
    Say ""
    Say "In game, on each character:  /lua run adventuretime" 'Cyan'
}
catch {
    Say "Unexpected error - nothing was changed." 'Red'
    Say $_.Exception.Message 'Red'
}
finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
