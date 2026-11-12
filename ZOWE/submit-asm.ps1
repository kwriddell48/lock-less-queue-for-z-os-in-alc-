# Submit jcl/asm_lked.jcl and download the spool under ZOWE/out/<jobid>.
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Jcl = Join-Path $Root 'jcl\asm_lked.jcl'
if (-not (Test-Path -LiteralPath $Jcl)) {
    throw "JCL not found: $Jcl"
}
if (-not $OutDir) {
    $OutDir = Join-Path $PSScriptRoot 'out'
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

Write-Host "Submit $Jcl"
Write-Host "Spool  $OutDir"

$raw = & zowe zos-jobs submit local-file $Jcl --directory $OutDir --extension .txt --completion-timeout 600 --rfj
$code = $LASTEXITCODE
$text = ($raw | Out-String).Trim()
if ($code -ne 0) {
    Write-Host $text
    exit $code
}

$job = $null
try {
    $parsed = $text | ConvertFrom-Json
    if ($parsed.data) { $job = $parsed.data } else { $job = $parsed }
} catch {
    Write-Host $text
    throw "Zowe did not return job JSON"
}

$jobId = [string]$job.jobid
$jobName = [string]$job.jobname
$ret = [string]$job.retcode
if (-not $jobId) {
    Write-Host $text
    throw "Zowe response has no jobid"
}

$spool = Join-Path $OutDir $jobId
Write-Host ''
Write-Host "$jobId $jobName $ret"
Write-Host "Spool  $spool"

$log = Get-ChildItem -LiteralPath $spool -Recurse -File -Filter 'JESMSGLG.txt' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($log) {
    Select-String -LiteralPath $log.FullName -Pattern 'JOB\d+\s+-(\S+)\s+(\d+)\s+\d+' |
        ForEach-Object {
            Write-Host ("  {0,-8} {1}" -f $_.Matches[0].Groups[1].Value, $_.Matches[0].Groups[2].Value)
        }
}

$files = @(Get-ChildItem -LiteralPath $spool -Recurse -File -ErrorAction SilentlyContinue)
Write-Host ''
Write-Host ("Done. {0} spool files." -f $files.Count)

if ($ret -match '(\d{4})\s*$') {
    $rc = [int]$Matches[1]
    if ($rc -gt 255) { $rc = 1 }
    exit $rc
}
if ($ret -match 'ABEND|JCL ERROR|CANCEL') {
    exit 1
}
