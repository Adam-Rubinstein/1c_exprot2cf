<#!
.SYNOPSIS
    Загрузка расширения из каталога файлов (репозиторий / Cursor) в указанную ИБ и выгрузка в .cfe (по умолчанию — каталог artifacts\cfe относительно корня репозитория).

.DESCRIPTION
    Один запуск с -Step All (по умолчанию): загрузка из каталога файлов в ИБ, обновление БД расширения, выгрузка .cfe.
    Пакетный режим конфигуратора: /LoadConfigFromFiles … -Extension, /UpdateDBCfg -Extension, /DumpCfg … -Extension.
    Имя расширения по умолчанию читается из src\cfe\Configuration.xml (<Properties><Name>).

.PARAMETER ExtensionFilesPath
    Каталог с файлами расширения (корень, где лежит Configuration.xml). По умолчанию — src\cfe рядом с репозиторием.

.PARAMETER InfoBasePath
    Каталог файловой ИБ (/F). Если не задан — из env.json (ключ default."--ibconnection").

.PARAMETER ExtensionName
    Внутреннее имя расширения (-Extension). Если не задано — из Configuration.xml.

.PARAMETER OutCfePath
    Полный путь к выходному .cfe. По умолчанию — <корень репозитория>\artifacts\cfe\cfe-export-YYYYMMDD-HHMMSS.cfe (ASCII-имя). Родительский каталог создаётся при необходимости.

.PARAMETER PlatformExe
    Полный путь к 1cv8.exe. Если не задан — ищется последняя установленная 8.3 в Program Files.

.PARAMETER WhatIf
    Только вывести найденные пути и аргументы запуска, без выполнения (аналог стандартного -WhatIf).

.PARAMETER SaveLog
    Сохранять объединённый лог в %TEMP%, фрагменты по фазам и копию в build-logs. По умолчанию выключено: временные /Out удаляются после успеха, в консоль — только краткий вывод.

.NOTES
    Расширение с таким именем должно уже существовать в ИБ (подключено к основной конфигурации).
    ИБ должна соответствовать расширяемой конфигурации (ERP), иначе загрузка завершится ошибкой.
#>
[CmdletBinding()]
param(
    [string] $ExtensionFilesPath = "",
    [string] $InfoBasePath = "",
    [string] $DbUser = "",
    [string] $DbPwd = "",
    [string] $ExtensionName = "",
    [string] $OutCfePath = "",
    [string] $PlatformExe = "",
    [string] $LogPath = "",
    [switch] $SaveLog,
    [switch] $WhatIf,
    [switch] $SkipUpdateDBCfg,
    [ValidateSet("All", "LoadOnly", "UpdateOnly", "DumpOnly")]
    [string] $Step = "All",
    [ValidateSet("Designer", "Ibcmd")]
    [string] $Engine = "Designer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
    if ($PSScriptRoot) {
        $cur = $PSScriptRoot
        for ($i = 0; $i -lt 8; $i++) {
            $ext = Join-Path $cur "src\cfe\Configuration.xml"
            $base = Join-Path $cur "src\cf\Configuration.xml"
            $envf = Join-Path $cur "env.json"
            if ((Test-Path -LiteralPath $ext) -or (Test-Path -LiteralPath $base) -or (Test-Path -LiteralPath $envf)) {
                return (Resolve-Path -LiteralPath $cur).Path
            }
            $parent = Split-Path -Parent $cur
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cur) { break }
            $cur = $parent
        }
        return (Resolve-Path -LiteralPath $PSScriptRoot).Path
    }
    return (Get-Location).Path
}

function Get-DirectoryLongPath([string] $directoryPath) {
    if ([string]::IsNullOrWhiteSpace($directoryPath)) {
        return $directoryPath
    }
    if (-not (Test-Path -LiteralPath $directoryPath)) {
        return $directoryPath
    }
    return (Get-Item -LiteralPath $directoryPath).FullName
}

function Get-ExtensionNameFromConfigurationXml([string] $extDir) {
    $xmlPath = Join-Path $extDir "Configuration.xml"
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        throw "Configuration.xml not found: $xmlPath"
    }
    $raw = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
    if ($raw -notmatch '(?s)<Properties>\s*.*?<Name>([^<]+)</Name>') {
        throw "Failed to read extension name from: $xmlPath"
    }
    return $Matches[1].Trim()
}

function Get-InfoBasePathFromEnvJson([string] $repoRoot) {
    $envJson = Join-Path $repoRoot "env.json"
    if (-not (Test-Path -LiteralPath $envJson)) { return $null }
    $j = Get-Content -LiteralPath $envJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $ib = $null
    if ($j.PSObject.Properties.Name -contains "default") {
        $d = $j.default
        if ($d.PSObject.Properties.Name -contains "--ibconnection") {
            $ib = $d."--ibconnection"
        }
    }
    if ([string]::IsNullOrWhiteSpace($ib)) { return $null }
    if ($ib -match '^/F"(.*)"\s*$') { return $Matches[1] }
    if ($ib -match "^/F'(.*)'\s*$") { return $Matches[1] }
    if ($ib -match "^/F(.+)$") { return $Matches[1].Trim().Trim('"') }
    return $ib
}

function Find-1CPlatformExe {
    $candidates = @()
    foreach ($root in @("${env:ProgramFiles}\1cv8", "${env:ProgramFiles(x86)}\1cv8")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $exe = Join-Path $_.FullName "bin\1cv8.exe"
            if (Test-Path -LiteralPath $exe) {
                $candidates += [pscustomobject]@{ Exe = $exe; Version = $_.Name }
            }
        }
    }
    if ($candidates.Count -eq 0) {
        throw "1cv8.exe not found under Program Files\1cv8. Pass -PlatformExe."
    }
    return ($candidates | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1).Exe
}

$repoRoot = Get-RepoRoot

if ([string]::IsNullOrWhiteSpace($ExtensionFilesPath)) {
    $ExtensionFilesPath = Join-Path (Join-Path $repoRoot "src") "cfe"
}
$ExtensionFilesPath = (Resolve-Path -LiteralPath $ExtensionFilesPath).Path

if ([string]::IsNullOrWhiteSpace($ExtensionName)) {
    $ExtensionName = Get-ExtensionNameFromConfigurationXml $ExtensionFilesPath
}

if ([string]::IsNullOrWhiteSpace($InfoBasePath)) {
    $parsed = Get-InfoBasePathFromEnvJson $repoRoot
    if ([string]::IsNullOrWhiteSpace($parsed)) {
        throw "InfoBasePath is empty and env.json default ib connection could not be parsed."
    }
    $InfoBasePath = $parsed
}
if (-not (Test-Path -LiteralPath $InfoBasePath)) {
    throw "Infobase folder not found: $InfoBasePath"
}

$envJsonPath = Join-Path $repoRoot "env.json"
if ([string]::IsNullOrWhiteSpace($DbUser) -and (Test-Path -LiteralPath $envJsonPath)) {
    $j = Get-Content -LiteralPath $envJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.default."--db-user") { $DbUser = [string]$j.default."--db-user" }
    if ($null -ne $j.default."--db-pwd") { $DbPwd = [string]$j.default."--db-pwd" }
}

if ([string]::IsNullOrWhiteSpace($PlatformExe)) {
    $PlatformExe = Find-1CPlatformExe
}
if (-not (Test-Path -LiteralPath $PlatformExe)) {
    throw "Platform executable not found: $PlatformExe"
}

if ([string]::IsNullOrWhiteSpace($OutCfePath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    # ASCII-only default filename avoids console/zip tooling edge cases; pass -OutCfePath for a custom path (e.g. Desktop).
    $cfeDir = Join-Path (Join-Path $repoRoot "artifacts") "cfe"
    $OutCfePath = Join-Path $cfeDir ("cfe-export-{0}.cfe" -f $stamp)
}

if ($SaveLog) {
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $tempLong = Get-DirectoryLongPath($env:TEMP)
        $LogPath = Join-Path $tempLong ("1c-export-extension-{0}.log" -f (Get-Date -Format "yyyyMMddHHmmss"))
    }
    $logParent = Split-Path -Parent $LogPath
    if (-not [string]::IsNullOrWhiteSpace($logParent) -and (Test-Path -LiteralPath $logParent)) {
        $LogPath = Join-Path (Get-DirectoryLongPath $logParent) (Split-Path -Leaf $LogPath)
    }
}
else {
    $LogPath = ""
}

$outParent = Split-Path -Parent $OutCfePath
if (-not [string]::IsNullOrWhiteSpace($outParent)) {
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
    $OutCfePath = Join-Path (Get-DirectoryLongPath $outParent) (Split-Path -Leaf $OutCfePath)
}

function Escape-1CPath([string] $p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '""' }
    return '"' + ($p -replace '"', '""') + '"'
}

function Format-1CFileConnectionString([string] $pathToFileIb) {
    return 'File="' + ($pathToFileIb -replace '"', '""') + '";'
}

$userArg = if ([string]::IsNullOrWhiteSpace($DbUser)) { "" } else { '/N' + (Escape-1CPath $DbUser) }

function New-BaseDesignerArgs {
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add("DESIGNER")
    $a.Add("/DisableStartupDialogs")
    # Same style as ArKuznetsov/1CFilesConverter ext2cfe.cmd: /IBConnectionString File="...";
    $a.Add("/IBConnectionString")
    $a.Add((Format-1CFileConnectionString $InfoBasePath))
    if (-not [string]::IsNullOrWhiteSpace($userArg)) { $a.Add($userArg) }
    # Empty password: omit /P (many 1C batch examples omit /P when password is empty).
    if (-not [string]::IsNullOrEmpty($DbPwd)) {
        $a.Add('/P' + (Escape-1CPath $DbPwd))
    }
    # Unary comma: return the list as a single object (otherwise PowerShell unwraps IEnumerable).
    return ,$a
}

function New-DumpCfgDesignerArgs {
    $a = New-BaseDesignerArgs
    $a.Add("/DumpCfg")
    $a.Add((Escape-1CPath $OutCfePath))
    $a.Add("-Extension")
    $a.Add($ExtensionName)
    return ,$a
}

function New-DumpDBCfgDesignerArgs {
    $a = New-BaseDesignerArgs
    $a.Add("/DumpDBCfg")
    $a.Add((Escape-1CPath $OutCfePath))
    $a.Add("-Extension")
    $a.Add($ExtensionName)
    return ,$a
}

function Test-ExportedCfeLooksValid([string] $cfePath) {
    if (-not (Test-Path -LiteralPath $cfePath)) {
        return $false
    }
    $len = (Get-Item -LiteralPath $cfePath).Length
    if ($len -lt 512) {
        return $false
    }
    return $true
}

function Get-IbcmdExePath {
    $bin = Split-Path -Parent $PlatformExe
    $ib = Join-Path $bin "ibcmd.exe"
    if (-not (Test-Path -LiteralPath $ib)) {
        throw "ibcmd.exe not found next to 1cv8.exe: $ib. Install full platform or use -Engine Designer."
    }
    return $ib
}

function Invoke-Ibcmd {
    param(
        [string[]] $IbcmdArguments,
        [string] $Title,
        [string] $FragmentLogPath
    )
    $exe = Get-IbcmdExePath
    $ibData = Join-Path (Split-Path -Parent $FragmentLogPath) "ibcmd-data"
    New-Item -ItemType Directory -Force -Path $ibData | Out-Null
    $fullArgs = [System.Collections.Generic.List[string]]::new()
    $fullArgs.AddRange($IbcmdArguments)
    Write-Host ""
    Write-Host "---- $Title (ibcmd) ----"
    Write-Host ($exe + " " + ($fullArgs -join " "))
    $errPath = $FragmentLogPath + ".stderr.txt"
    $p = Start-Process -FilePath $exe -ArgumentList $fullArgs -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $FragmentLogPath -RedirectStandardError $errPath
    if ($null -eq $p) {
        throw "Start-Process returned null for ibcmd. Exe=$exe"
    }
    if (Test-Path -LiteralPath $errPath) {
        $errTxt = Get-Content -LiteralPath $errPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($errTxt)) {
            Add-Content -LiteralPath $FragmentLogPath -Value "`n--- stderr ---`n$errTxt" -Encoding UTF8
        }
    }
    $exit = $p.ExitCode
    if ($null -eq $exit) { return 1 }
    return [int]$exit
}

function Invoke-LoadPhaseEngine {
    param([string] $FragmentLogPath)
    if ($Engine -eq "Ibcmd") {
        $u = if ([string]::IsNullOrWhiteSpace($DbUser)) { "" } else { $DbUser }
        $pwdPlain = $DbPwd
        return (Invoke-Ibcmd -Title "config import (extension from XML)" -FragmentLogPath $FragmentLogPath -IbcmdArguments @(
                "infobase", "config", "import",
                ("--data=" + (Join-Path (Split-Path -Parent $FragmentLogPath) "ibcmd-data")),
                ("--db-path=" + $InfoBasePath),
                ("--user=" + $u),
                ("--password=" + $pwdPlain),
                ("--extension=" + $ExtensionName),
                $ExtensionFilesPath
            ))
    }
    return (Invoke-DesignerPhase -Title "Load extension from files" -Arguments $argsLoad -FragmentLogPath $FragmentLogPath)
}

function Invoke-UpdatePhaseEngine {
    param([string] $FragmentLogPath)
    if ($Engine -eq "Ibcmd") {
        $u = if ([string]::IsNullOrWhiteSpace($DbUser)) { "" } else { $DbUser }
        $pwdPlain = $DbPwd
        return (Invoke-Ibcmd -Title "config apply (extension)" -FragmentLogPath $FragmentLogPath -IbcmdArguments @(
                "infobase", "config", "apply",
                ("--data=" + (Join-Path (Split-Path -Parent $FragmentLogPath) "ibcmd-data")),
                ("--db-path=" + $InfoBasePath),
                ("--user=" + $u),
                ("--password=" + $pwdPlain),
                ("--extension=" + $ExtensionName),
                "--force"
            ))
    }
    return (Invoke-DesignerPhase -Title "Update database configuration (extension)" -Arguments $argsUpdate -FragmentLogPath $FragmentLogPath)
}

function Invoke-DumpPhaseEngine {
    param([string] $FragmentLogPath)
    if ($Engine -eq "Ibcmd") {
        $u = if ([string]::IsNullOrWhiteSpace($DbUser)) { "" } else { $DbUser }
        $pw = $DbPwd
        return (Invoke-Ibcmd -Title "config save (extension to CFE)" -FragmentLogPath $FragmentLogPath -IbcmdArguments @(
                "infobase", "config", "save",
                ("--data=" + (Join-Path (Split-Path -Parent $FragmentLogPath) "ibcmd-data")),
                ("--db-path=" + $InfoBasePath),
                ("--user=" + $u),
                ("--password=" + $pw),
                ("--extension=" + $ExtensionName),
                $OutCfePath
            ))
    }
    $dumpCfgArgs = New-DumpCfgDesignerArgs
    $code = Invoke-DesignerPhase -Title "Dump extension to CFE (/DumpCfg)" -Arguments $dumpCfgArgs -FragmentLogPath $FragmentLogPath
    if ($code -eq 0 -and (Test-ExportedCfeLooksValid $OutCfePath)) {
        return 0
    }
    if ($code -eq 0) {
        Write-Warning "DumpCfg returned 0 but .cfe is missing or too small; retrying with /DumpDBCfg (export from DB-stored extension)."
    }
    else {
        Write-Warning "DumpCfg failed (exit $code); retrying with /DumpDBCfg."
    }
    $dumpDir = Split-Path -Parent $FragmentLogPath
    $dumpBase = [IO.Path]::GetFileNameWithoutExtension($FragmentLogPath)
    $altLog = Join-Path $dumpDir ($dumpBase + "-dbcfg.log")
    $dumpDbArgs = New-DumpDBCfgDesignerArgs
    $code2 = Invoke-DesignerPhase -Title "Dump extension to CFE (/DumpDBCfg)" -Arguments $dumpDbArgs -FragmentLogPath $altLog
    if ($code2 -eq 0 -and (Test-ExportedCfeLooksValid $OutCfePath)) {
        return 0
    }
    if ($code2 -eq 0) {
        Write-Warning ".cfe still missing or too small after /DumpDBCfg. При необходимости повторите с -SaveLog и смотрите хвост временных /Out в %TEMP%."
        return 1
    }
    return $code2
}

function Invoke-DesignerPhase {
    param(
        [string] $Title,
        [System.Collections.Generic.List[string]] $Arguments,
        [string] $FragmentLogPath
    )
    # Copy list: do not mutate shared $argsLoad / $argsUpdate (would corrupt later phases and -WhatIf output).
    $execArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $Arguments) { $execArgs.Add($a) }
    $execArgs.Add("/Out")
    $execArgs.Add((Escape-1CPath $FragmentLogPath))
    Write-Host ""
    Write-Host "---- $Title ----"
    Write-Host ($execArgs -join " ")
    $p = Start-Process -FilePath $PlatformExe -ArgumentList $execArgs -Wait -PassThru -NoNewWindow
    if ($null -eq $p) {
        throw "Start-Process returned null (Designer did not start?). PlatformExe=$PlatformExe"
    }
    $exit = $p.ExitCode
    if ($null -eq $exit) { return 1 }
    return [int]$exit
}

function Merge-FragmentLogs([string] $destPath, [string[]] $fragmentPaths) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("==== Export log (merged) " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + " ====")
    foreach ($fp in $fragmentPaths) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("======== " + (Split-Path -Leaf $fp) + " ========")
        if (Test-Path -LiteralPath $fp) {
            $text = Get-Content -LiteralPath $fp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $text) { $text = Get-Content -LiteralPath $fp -Raw -Encoding Default -ErrorAction SilentlyContinue }
            if ($null -eq $text) { $text = "" }
            [void]$sb.AppendLine($text.TrimEnd())
        }
        else {
            [void]$sb.AppendLine("(log file missing)")
        }
    }
    [IO.File]::WriteAllText($destPath, $sb.ToString().TrimEnd() + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Copy-ExportLogToRepo([string] $sourceLogPath) {
    try {
        $dir = Join-Path $repoRoot "build-logs"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $dest = Join-Path $dir "last-cfe-export.log"
        if (Test-Path -LiteralPath $sourceLogPath) {
            Copy-Item -LiteralPath $sourceLogPath -Destination $dest -Force
            Write-Host "Repo log copy: $dest"
        }
    }
    catch {
        Write-Warning ("Could not mirror log into repo/build-logs: " + $_.Exception.Message)
    }
}

function Write-CloseDesignerWarning {
    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  IMPORTANT: close ALL 1C Designer windows for this file infobase." -ForegroundColor Yellow
    Write-Host "  If Designer is open on the same IB, batch mode often hangs or fails (no .cfe)." -ForegroundColor Yellow
    Write-Host ("  Infobase folder: " + $InfoBasePath) -ForegroundColor Yellow
    Write-Host "----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
}

function Get-DbcfgOutPath([string] $fragmentLogPath) {
    $dir = Split-Path -Parent $fragmentLogPath
    $base = [IO.Path]::GetFileNameWithoutExtension($fragmentLogPath)
    return (Join-Path $dir ($base + "-dbcfg.log"))
}

function Remove-DesignerOutFiles([string[]] $fragmentPaths) {
    foreach ($p in $fragmentPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }
        $dbc = Get-DbcfgOutPath $p
        if (Test-Path -LiteralPath $dbc) {
            Remove-Item -LiteralPath $dbc -Force -ErrorAction SilentlyContinue
        }
    }
}

function Finish-Run([string[]] $fragments, [int] $exitCode, [string] $message, [string] $SuccessNote = "") {
    if ($SaveLog) {
        Merge-FragmentLogs -destPath $LogPath -fragmentPaths $fragments
        Copy-ExportLogToRepo -sourceLogPath $LogPath
        if ($exitCode -ne 0) {
            if (-not [string]::IsNullOrWhiteSpace($message)) {
                Write-Warning $message
            }
            Get-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 160 | Write-Host
        }
        elseif (-not [string]::IsNullOrWhiteSpace($SuccessNote)) {
            Write-Host $SuccessNote
        }
        Write-Host "Log: $LogPath"
    }
    else {
        $pathsForTail = [System.Collections.Generic.List[string]]::new()
        foreach ($fp in $fragments) {
            if ([string]::IsNullOrWhiteSpace($fp)) { continue }
            if (-not $pathsForTail.Contains($fp)) { [void]$pathsForTail.Add($fp) }
            $dbc = Get-DbcfgOutPath $fp
            if ((Test-Path -LiteralPath $dbc) -and -not $pathsForTail.Contains($dbc)) { [void]$pathsForTail.Add($dbc) }
        }
        if ($exitCode -ne 0) {
            if (-not [string]::IsNullOrWhiteSpace($message)) {
                Write-Warning $message
            }
            Write-Warning "Close 1C Designer for this IB if it was open, then retry. For full logs on disk use -SaveLog."
            foreach ($tp in $pathsForTail) {
                if (Test-Path -LiteralPath $tp) {
                    Write-Host "--- tail: $(Split-Path -Leaf $tp) ---"
                    Get-Content -LiteralPath $tp -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 120 | Write-Host
                }
            }
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($SuccessNote)) {
                Write-Host $SuccessNote
            }
        }
        Remove-DesignerOutFiles -fragmentPaths $fragments
    }
    exit $exitCode
}

# /LoadConfigFromFiles: same argument order as ArKuznetsov/1CFilesConverter ext2cfe.cmd:
# /LoadConfigFromFiles "<xmlRoot>" -Extension <name>
$argsLoad = New-BaseDesignerArgs
$argsLoad.Add("/LoadConfigFromFiles")
$argsLoad.Add((Escape-1CPath $ExtensionFilesPath))
$argsLoad.Add("-Extension")
$argsLoad.Add($ExtensionName)

$argsUpdate = New-BaseDesignerArgs
$argsUpdate.Add("/UpdateDBCfg")
$argsUpdate.Add("-Extension")
$argsUpdate.Add($ExtensionName)

Write-Host "Platform:   $PlatformExe"
Write-Host "Infobase:   $InfoBasePath"
Write-Host "Ext files:  $ExtensionFilesPath"
Write-Host "Extension:  $ExtensionName"
Write-Host "Output CFE: $OutCfePath"
if ($SaveLog) {
    Write-Host "Log:        $LogPath"
}
else {
    Write-Host "Log:        off (add -SaveLog to write merged log files)"
}
Write-Host "Step:       $Step"
Write-Host "Engine:     $Engine"
Write-Host ""

if ($WhatIf) {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  DRY RUN (-WhatIf): Designer is NOT started." -ForegroundColor Yellow
    Write-Host "  No .cfe file is created and no log files are written." -ForegroundColor Yellow
    Write-Host "  Run the same script WITHOUT -WhatIf to export a real .cfe." -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "NOTE: In -WhatIf mode no log files are created (paths above are planned only)."
    if ($Engine -eq "Ibcmd") {
        Write-Host "NOTE: -Engine Ibcmd uses ibcmd.exe next to 1cv8.exe (see Infostart / 1C docs: ibcmd infobase config import|apply|save)."
    }
    Write-Host "WhatIf: planned phases:"
    if ($Step -eq "All") {
        Write-Host "1)" ($argsLoad -join " ")
        if (-not $SkipUpdateDBCfg) {
            Write-Host "2)" ($argsUpdate -join " ")
        }
        Write-Host "3)" ((New-DumpCfgDesignerArgs) -join " ")
    }
    elseif ($Step -eq "LoadOnly") {
        Write-Host "1)" ($argsLoad -join " ")
    }
    elseif ($Step -eq "UpdateOnly") {
        Write-Host "1)" ($argsUpdate -join " ")
    }
    else {
        Write-Host "1)" ((New-DumpCfgDesignerArgs) -join " ")
    }
    Write-Host ""
    Write-Host "WhatIf: Designer was not started."
    exit 0
}

Write-Host "Real export: Designer will run; on success the .cfe will be written to the path above." -ForegroundColor Green
Write-Host ""

Write-CloseDesignerWarning

$runId = Get-Date -Format "yyyyMMddHHmmssfff"
if ($SaveLog) {
    $fragDir = Join-Path (Split-Path -Parent $LogPath) ("1c-export-extension-fragments-" + $runId)
    New-Item -ItemType Directory -Force -Path $fragDir | Out-Null
    $logLoad = Join-Path $fragDir "01-load.log"
    $logUpdate = Join-Path $fragDir "02-update.log"
    $logDump = Join-Path $fragDir "03-dump.log"
    Write-Host "Fragments:  $fragDir"
    Write-Host ""
    $logHeader = @"
==== 1C extension export session started ====
Time (local): $(Get-Date -Format "o")
Platform: $PlatformExe
Infobase: $InfoBasePath
Extension: $ExtensionName
Ext files: $ExtensionFilesPath
Step: $Step
Engine: $Engine
Fragment logs directory: $fragDir
"@
    [IO.File]::WriteAllText($LogPath, $logHeader.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Started writing log file: $LogPath"
}
else {
    $tid = [Guid]::NewGuid().ToString("N")
    $logLoad = Join-Path $env:TEMP ("1c-ext-$tid-01.log")
    $logUpdate = Join-Path $env:TEMP ("1c-ext-$tid-02.log")
    $logDump = Join-Path $env:TEMP ("1c-ext-$tid-03.log")
}

if ($Step -eq "LoadOnly") {
    $code = Invoke-LoadPhaseEngine -FragmentLogPath $logLoad
    if ($code -ne 0) {
        Finish-Run -fragments @($logLoad) -exitCode $code -message "Designer failed on LOAD (exit $code)."
    }
    Finish-Run -fragments @($logLoad) -exitCode 0 -message "" -SuccessNote "LoadOnly: OK. If IB is correct, next run full export (-Step All) or UpdateOnly/DumpOnly."
}

if ($Step -eq "UpdateOnly") {
    $code = Invoke-UpdatePhaseEngine -FragmentLogPath $logUpdate
    if ($code -ne 0) {
        Finish-Run -fragments @($logUpdate) -exitCode $code -message "Designer failed on UPDATE (exit $code)."
    }
    Finish-Run -fragments @($logUpdate) -exitCode 0 -message "" -SuccessNote "UpdateOnly: OK."
}

if ($Step -eq "DumpOnly") {
    $code = Invoke-DumpPhaseEngine -FragmentLogPath $logDump
    if ($code -ne 0) {
        Finish-Run -fragments @($logDump) -exitCode $code -message "Designer failed on DUMP (exit $code)."
    }
    Finish-Run -fragments @($logDump) -exitCode 0 -message "" -SuccessNote ("DumpOnly: OK. CFE: " + $OutCfePath)
}

# Step = All
$code = Invoke-LoadPhaseEngine -FragmentLogPath $logLoad
if ($code -ne 0) {
    Finish-Run -fragments @($logLoad) -exitCode $code -message "Designer failed on LOAD (exit $code)."
}

if (-not $SkipUpdateDBCfg) {
    $code = Invoke-UpdatePhaseEngine -FragmentLogPath $logUpdate
    if ($code -ne 0) {
        Finish-Run -fragments @($logLoad, $logUpdate) -exitCode $code -message "Designer failed on UPDATE (exit $code)."
    }
}

$code = Invoke-DumpPhaseEngine -FragmentLogPath $logDump
if ($code -ne 0) {
    if ($SkipUpdateDBCfg) {
        Finish-Run -fragments @($logLoad, $logDump) -exitCode $code -message "Designer failed on DUMP (exit $code)."
    }
    else {
        Finish-Run -fragments @($logLoad, $logUpdate, $logDump) -exitCode $code -message "Designer failed on DUMP (exit $code)."
    }
}

if (-not (Test-ExportedCfeLooksValid $OutCfePath)) {
    $msg = "Export finished but .cfe is missing or too small: $OutCfePath (close Designer for this IB and retry; try -SaveLog)."
    if ($SkipUpdateDBCfg) {
        Finish-Run -fragments @($logLoad, $logDump) -exitCode 1 -message $msg
    }
    else {
        Finish-Run -fragments @($logLoad, $logUpdate, $logDump) -exitCode 1 -message $msg
    }
}

Write-Host ""
Write-Host "Output .cfe file (repo subfolder cfe by default):" -ForegroundColor Green
Write-Host $OutCfePath -ForegroundColor Green
Write-Host ""

if ($SkipUpdateDBCfg) {
    Finish-Run -fragments @($logLoad, $logDump) -exitCode 0 -message "" -SuccessNote ("Done. CFE: " + $OutCfePath)
}
else {
    Finish-Run -fragments @($logLoad, $logUpdate, $logDump) -exitCode 0 -message "" -SuccessNote ("Done. CFE: " + $OutCfePath)
}
