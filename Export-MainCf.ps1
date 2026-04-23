<#!
.SYNOPSIS
    Загрузка основной конфигурации из каталога файлов в файловую ИБ и выгрузка в .cf (по умолчанию — каталог cf\ в корне репозитория).

.DESCRIPTION
    Пакетный режим конфигуратора без ключа -Extension: /LoadConfigFromFiles, /UpdateDBCfg, /DumpCfg в файл .cf.
    Реализовано через движок Designer (1cv8.exe DESIGNER). ИБ должна соответствовать загружаемой конфигурации.

.PARAMETER ConfigFilesPath
    Каталог с файлами основной конфигурации (корень с Configuration.xml). По умолчанию — base-conf рядом со скриптом.

.PARAMETER InfoBasePath
    Каталог файловой ИБ (/F). Если не задан — из env.json (ключ default."--ibconnection").

.PARAMETER OutCfPath
    Полный путь к выходному .cf. По умолчанию — <корень репозитория>\cf\cf-export-YYYYMMDD-HHMMSS.cf.

.PARAMETER WhatIf
    Только вывести пути и аргументы запуска, без выполнения.

.NOTES
    Для крупных типовых конфигураций каталог файлов может быть очень большим — решайте отдельно, коммитить ли его в Git (см. README.md).
#>
[CmdletBinding()]
param(
    [string] $ConfigFilesPath = "",
    [string] $InfoBasePath = "",
    [string] $DbUser = "",
    [string] $DbPwd = "",
    [string] $OutCfPath = "",
    [string] $PlatformExe = "",
    [string] $LogPath = "",
    [switch] $WhatIf,
    [switch] $SkipUpdateDBCfg,
    [ValidateSet("All", "LoadOnly", "UpdateOnly", "DumpOnly")]
    [string] $Step = "All"
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

function Get-ConfigurationNameFromXml([string] $cfgDir) {
    $xmlPath = Join-Path $cfgDir "Configuration.xml"
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
    if ($raw -notmatch '(?s)<Properties>\s*.*?<Name>([^<]+)</Name>') {
        return $null
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

if ([string]::IsNullOrWhiteSpace($ConfigFilesPath)) {
    $ConfigFilesPath = Join-Path $repoRoot "base-conf"
}
$ConfigFilesPath = (Resolve-Path -LiteralPath $ConfigFilesPath).Path

$cfgXml = Join-Path $ConfigFilesPath "Configuration.xml"
if (-not (Test-Path -LiteralPath $cfgXml)) {
    throw "Configuration.xml not found (main config root): $cfgXml"
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

if ([string]::IsNullOrWhiteSpace($OutCfPath)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $cfDir = Join-Path $repoRoot "cf"
    $OutCfPath = Join-Path $cfDir ("cf-export-{0}.cf" -f $stamp)
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $tempLong = Get-DirectoryLongPath($env:TEMP)
    $LogPath = Join-Path $tempLong ("1c-export-main-{0}.log" -f (Get-Date -Format "yyyyMMddHHmmss"))
}

$outParent = Split-Path -Parent $OutCfPath
if (-not [string]::IsNullOrWhiteSpace($outParent)) {
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
    $OutCfPath = Join-Path (Get-DirectoryLongPath $outParent) (Split-Path -Leaf $OutCfPath)
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
    $a.Add("/IBConnectionString")
    $a.Add((Format-1CFileConnectionString $InfoBasePath))
    if (-not [string]::IsNullOrWhiteSpace($userArg)) { $a.Add($userArg) }
    if (-not [string]::IsNullOrEmpty($DbPwd)) {
        $a.Add('/P' + (Escape-1CPath $DbPwd))
    }
    return ,$a
}

function New-DumpCfgDesignerArgs {
    $a = New-BaseDesignerArgs
    $a.Add("/DumpCfg")
    $a.Add((Escape-1CPath $OutCfPath))
    return ,$a
}

function New-DumpDBCfgDesignerArgs {
    $a = New-BaseDesignerArgs
    $a.Add("/DumpDBCfg")
    $a.Add((Escape-1CPath $OutCfPath))
    return ,$a
}

function Test-ExportedCfLooksValid([string] $cfPath) {
    if (-not (Test-Path -LiteralPath $cfPath)) {
        return $false
    }
    $len = (Get-Item -LiteralPath $cfPath).Length
    if ($len -lt 512) {
        return $false
    }
    return $true
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

function Invoke-LoadPhase {
    param([string] $FragmentLogPath)
    return (Invoke-DesignerPhase -Title "Load main configuration from files" -Arguments $argsLoad -FragmentLogPath $FragmentLogPath)
}

function Invoke-UpdatePhase {
    param([string] $FragmentLogPath)
    return (Invoke-DesignerPhase -Title "Update database configuration (main)" -Arguments $argsUpdate -FragmentLogPath $FragmentLogPath)
}

function Invoke-DumpPhase {
    param([string] $FragmentLogPath)
    $dumpCfgArgs = New-DumpCfgDesignerArgs
    $code = Invoke-DesignerPhase -Title "Dump main configuration to CF (/DumpCfg)" -Arguments $dumpCfgArgs -FragmentLogPath $FragmentLogPath
    if ($code -eq 0 -and (Test-ExportedCfLooksValid $OutCfPath)) {
        return 0
    }
    if ($code -eq 0) {
        Write-Warning "DumpCfg returned 0 but .cf is missing or too small; retrying with /DumpDBCfg."
    }
    else {
        Write-Warning "DumpCfg failed (exit $code); retrying with /DumpDBCfg."
    }
    $dumpDir = Split-Path -Parent $FragmentLogPath
    $dumpBase = [IO.Path]::GetFileNameWithoutExtension($FragmentLogPath)
    $altLog = Join-Path $dumpDir ($dumpBase + "-dbcfg.log")
    $dumpDbArgs = New-DumpDBCfgDesignerArgs
    $code2 = Invoke-DesignerPhase -Title "Dump main configuration to CF (/DumpDBCfg)" -Arguments $dumpDbArgs -FragmentLogPath $altLog
    if ($code2 -eq 0 -and (Test-ExportedCfLooksValid $OutCfPath)) {
        return 0
    }
    if ($code2 -eq 0) {
        Write-Warning ".cf still missing or too small after /DumpDBCfg. Check merged log and 03-dump*.log fragments."
        return 1
    }
    return $code2
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
        $dest = Join-Path $dir "last-main-cf-export.log"
        if (Test-Path -LiteralPath $sourceLogPath) {
            Copy-Item -LiteralPath $sourceLogPath -Destination $dest -Force
            Write-Host "Repo log copy: $dest"
        }
    }
    catch {
        Write-Warning ("Could not mirror log into repo/build-logs: " + $_.Exception.Message)
    }
}

$argsLoad = New-BaseDesignerArgs
$argsLoad.Add("/LoadConfigFromFiles")
$argsLoad.Add((Escape-1CPath $ConfigFilesPath))

$argsUpdate = New-BaseDesignerArgs
$argsUpdate.Add("/UpdateDBCfg")

$configName = Get-ConfigurationNameFromXml $ConfigFilesPath

Write-Host "Platform:   $PlatformExe"
Write-Host "Infobase:   $InfoBasePath"
Write-Host "Config XML: $ConfigFilesPath"
if ($configName) { Write-Host "Config name (from XML): $configName" }
Write-Host "Output CF:  $OutCfPath"
Write-Host "Log:        $LogPath"
Write-Host "Step:       $Step"
Write-Host ""

if ($WhatIf) {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  DRY RUN (-WhatIf): Designer is NOT started." -ForegroundColor Yellow
    Write-Host "  No .cf file is created and no log files are written." -ForegroundColor Yellow
    Write-Host "  Run the same script WITHOUT -WhatIf to export a real .cf." -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "NOTE: In -WhatIf mode no log files are created (paths above are planned only)."
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

Write-Host "Real export: Designer will run; on success the .cf will be written to the path above." -ForegroundColor Green
Write-Host ""

$runId = Get-Date -Format "yyyyMMddHHmmssfff"
$fragDir = Join-Path (Split-Path -Parent $LogPath) ("1c-export-main-fragments-" + $runId)
New-Item -ItemType Directory -Force -Path $fragDir | Out-Null
$logLoad = Join-Path $fragDir "01-load.log"
$logUpdate = Join-Path $fragDir "02-update.log"
$logDump = Join-Path $fragDir "03-dump.log"
Write-Host "Fragments:  $fragDir"
Write-Host ""

$logHeader = @"
==== 1C main configuration export session started ====
Time (local): $(Get-Date -Format "o")
Platform: $PlatformExe
Infobase: $InfoBasePath
Config files: $ConfigFilesPath
Step: $Step
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
    $code = Invoke-LoadPhase -FragmentLogPath $logLoad
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logLoad) -exitCode $code -message "Designer failed on LOAD (exit $code). See: $LogPath"
    }
    Finish-WithMergedLog -fragments @($logLoad) -exitCode 0 -message "" -SuccessNote "LoadOnly: OK. Next run -Step All or UpdateOnly/DumpOnly."
}

if ($Step -eq "UpdateOnly") {
    $code = Invoke-UpdatePhase -FragmentLogPath $logUpdate
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logUpdate) -exitCode $code -message "Designer failed on UPDATE (exit $code). See: $LogPath"
    }
    Finish-WithMergedLog -fragments @($logUpdate) -exitCode 0 -message "" -SuccessNote "UpdateOnly: OK."
}

if ($Step -eq "DumpOnly") {
    $code = Invoke-DumpPhase -FragmentLogPath $logDump
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logDump) -exitCode $code -message "Designer failed on DUMP (exit $code). See: $LogPath"
    }
    Finish-WithMergedLog -fragments @($logDump) -exitCode 0 -message "" -SuccessNote ("DumpOnly: OK. CF: " + $OutCfPath)
}

$code = Invoke-LoadPhase -FragmentLogPath $logLoad
if ($code -ne 0) {
    Finish-WithMergedLog -fragments @($logLoad) -exitCode $code -message "Designer failed on LOAD (exit $code). See: $LogPath"
}

if (-not $SkipUpdateDBCfg) {
    $code = Invoke-UpdatePhase -FragmentLogPath $logUpdate
    if ($code -ne 0) {
        Finish-WithMergedLog -fragments @($logLoad, $logUpdate) -exitCode $code -message "Designer failed on UPDATE (exit $code). See: $LogPath"
    }
}

$code = Invoke-DumpPhase -FragmentLogPath $logDump
if ($code -ne 0) {
    if ($SkipUpdateDBCfg) {
        Finish-WithMergedLog -fragments @($logLoad, $logDump) -exitCode $code -message "Designer failed on DUMP (exit $code). See: $LogPath"
    }
    else {
        Finish-WithMergedLog -fragments @($logLoad, $logUpdate, $logDump) -exitCode $code -message "Designer failed on DUMP (exit $code). See: $LogPath"
    }
}

if ($SkipUpdateDBCfg) {
    Finish-WithMergedLog -fragments @($logLoad, $logDump) -exitCode 0 -message "" -SuccessNote ("Done. CF: " + $OutCfPath)
}
else {
    Finish-WithMergedLog -fragments @($logLoad, $logUpdate, $logDump) -exitCode 0 -message "" -SuccessNote ("Done. CF: " + $OutCfPath)
}
