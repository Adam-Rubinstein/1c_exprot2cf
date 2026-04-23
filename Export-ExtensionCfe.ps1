<#!
.SYNOPSIS
    Загрузка расширения из каталога файлов (репозиторий / Cursor) в указанную ИБ и выгрузка в .cfe (по умолчанию — каталог cfe\ в корне репозитория).

.DESCRIPTION
    Один запуск с -Step All (по умолчанию): загрузка из каталога файлов в ИБ, обновление БД расширения, выгрузка .cfe.
    Пакетный режим конфигуратора: /LoadConfigFromFiles … -Extension, /UpdateDBCfg -Extension, /DumpCfg … -Extension.
    Имя расширения по умолчанию читается из ext-ad\Configuration.xml (<Properties><Name>).

.PARAMETER ExtensionFilesPath
    Каталог с файлами расширения (корень, где лежит Configuration.xml). По умолчанию — ext-ad рядом со скриптом.

.PARAMETER InfoBasePath
    Каталог файловой ИБ (/F). Если не задан — из env.json (ключ default."--ibconnection").

.PARAMETER ExtensionName
    Внутреннее имя расширения (-Extension). Если не задано — из Configuration.xml.

.PARAMETER OutCfePath
    Полный путь к выходному .cfe. По умолчанию — <корень репозитория>\cfe\cfe-export-YYYYMMDD-HHMMSS.cfe (ASCII-имя). Родительский каталог создаётся при необходимости.

.PARAMETER PlatformExe
    Полный путь к 1cv8.exe. Если не задан — ищется последняя установленная 8.3 в Program Files.

.PARAMETER WhatIf
    Только вывести найденные пути и аргументы запуска, без выполнения (аналог стандартного -WhatIf).

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
    if ($PSScriptRoot) { return (Resolve-Path $PSScriptRoot).Path }
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
    $ExtensionFilesPath = Join-Path $repoRoot "ext-ad"
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
    $cfeDir = Join-Path $repoRoot "cfe"
    $OutCfePath = Join-Path $cfeDir ("cfe-export-{0}.cfe" -f $stamp)
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $tempLong = Get-DirectoryLongPath($env:TEMP)
    $LogPath = Join-Path $tempLong ("1c-export-extension-{0}.log" -f (Get-Date -Format "yyyyMMddHHmmss"))
}

$outParent = Split-Path -Parent $OutCfePath
if (-not [string]::IsNullOrWhiteSpace($outParent)) {
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
    $OutCfePath = Join-Path (Get-DirectoryLongPath $outParent) (Split-Path -Leaf $OutCfePath)
}
$logParent = Split-Path -Parent $LogPath
if (-not [string]::IsNullOrWhiteSpace($logParent) -and (Test-Path -LiteralPath $logParent)) {
    $LogPath = Join-Path (Get-DirectoryLongPath $logParent) (Split-Path -Leaf $LogPath)
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
        Write-Warning ".cfe still missing or too small after /DumpDBCfg. Check merged log and 03-dump*.log fragments."
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
    $Arguments.Add("/Out")
    $Arguments.Add((Escape-1CPath $FragmentLogPath))
    Write-Host ""
    Write-Host "---- $Title ----"
    Write-Host ($Arguments -join " ")
    $p = Start-Process -FilePath $PlatformExe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
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
Write-Host "Log:        $LogPath"
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
    Write-Host "(WhatIf) Planned phases:"
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
    Write-Host "(WhatIf) Designer was not started."
    exit 0
}

Write-Host "Real export: Designer will run; on success the .cfe will be written to the path above." -ForegroundColor Green
Write-Host ""

$runId = Get-Date -Format "yyyyMMddHHmmssfff"
$fragDir = Join-Path (Split-Path -Parent $LogPath) ("1c-export-extension-fragments-" + $runId)
New-Item -ItemType Directory -Force -Path $fragDir | Out-Null
$logLoad = Join-Path $fragDir "01-load.log"
$logUpdate = Join-Path $fragDir "02-update.log"
$logDump = Join-Path $fragDir "03-dump.log"
Write-Host "Fragments:  $fragDir"
Write-Host ""

# Create aggregate log immediately on real runs so the path printed above always exists on disk.
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

function Finish-WithMergedLog([string[]] $fragments, [int] $exitCode, [string] $message, [string] $SuccessNote = "") {
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
    exit $exitCode
}

if ($Step -eq "LoadOnly") {
    $code = Invoke-LoadPhaseEngine -FragmentLogPath $logLoad
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logLoad) -exitCode $code -message "Designer failed on LOAD (exit $code). See: $LogPath"
    }
    Finish-WithMergedLog -fragments @($logLoad) -exitCode 0 -message "" -SuccessNote "LoadOnly: OK. If IB is correct, next run full export (-Step All) or UpdateOnly/DumpOnly."
}

if ($Step -eq "UpdateOnly") {
    $code = Invoke-UpdatePhaseEngine -FragmentLogPath $logUpdate
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logUpdate) -exitCode $code -message "Designer failed on UPDATE (exit $code). See: $LogPath"
    }
    Finish-WithMergedLog -fragments @($logUpdate) -exitCode 0 -message "" -SuccessNote "UpdateOnly: OK."
}

if ($Step -eq "DumpOnly") {
    $code = Invoke-DumpPhaseEngine -FragmentLogPath $logDump
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logDump) -exitCode $code -message "Designer failed on DUMP (exit $code). See: $LogPath"
    }
    Finish-WithMergedLog -fragments @($logDump) -exitCode 0 -message "" -SuccessNote ("DumpOnly: OK. CFE: " + $OutCfePath)
}

# Step = All
$code = Invoke-LoadPhaseEngine -FragmentLogPath $logLoad
if ($code -ne 0) {
    Finish-WithMergedLog -fragments @($logLoad) -exitCode $code -message "Designer failed on LOAD (exit $code). See: $LogPath"
}

if (-not $SkipUpdateDBCfg) {
    $code = Invoke-UpdatePhaseEngine -FragmentLogPath $logUpdate
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logLoad, $logUpdate) -exitCode $code -message "Designer failed on UPDATE (exit $code). See: $LogPath"
    }
}

$code = Invoke-DumpPhaseEngine -FragmentLogPath $logDump
if ($code -ne 0) {
    if ($SkipUpdateDBCfg) {
        Finish-WithMergedLog -fragments @($logLoad, $logDump) -exitCode $code -message "Designer failed on DUMP (exit $code). See: $LogPath"
    }
    else {
        Finish-WithMergedLog -fragments @($logLoad, $logUpdate, $logDump) -exitCode $code -message "Designer failed on DUMP (exit $code). See: $LogPath"
    }
}

if ($SkipUpdateDBCfg) {
    Finish-WithMergedLog -fragments @($logLoad, $logDump) -exitCode 0 -message "" -SuccessNote ("Done. CFE: " + $OutCfePath)
}
else {
    Finish-WithMergedLog -fragments @($logLoad, $logUpdate, $logDump) -exitCode 0 -message "" -SuccessNote ("Done. CFE: " + $OutCfePath)
}
