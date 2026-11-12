# Upload TEST sources. Does not submit a job.
# qstub.asm goes to QUEUE.ASM. .c goes to QUEUE.C.
# .h goes to QUEUE.H. Both PDS are FB 80 and must exist.
param(
    [string]$Hlq = 'Z72675'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Test = Join-Path $Root 'TEST'
if (-not (Test-Path -LiteralPath $Test)) {
    throw "TEST directory not found: $Test"
}

function Send-Member {
    param(
        [System.IO.FileInfo]$File,
        [string]$Dsn
    )
    $Member = $File.BaseName.ToUpperInvariant()
    if ($Member.Length -lt 1 -or $Member.Length -gt 8) {
        throw "Member name must be 1-8 characters: $($File.Name)"
    }
    if ($Member -notmatch '^[A-Z@#$][A-Z0-9@#$]{0,7}$') {
        throw "Member name is not a PDS name: $Member"
    }
    $Target = "${Dsn}($Member)"
    Write-Host "Upload $($File.Name) -> $Target"
    & zowe files upload file-to-data-set $File.FullName $Target --migrated-recall wait --response-timeout 180
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$Asm = Get-ChildItem -LiteralPath $Test -File -Filter '*.asm'
foreach ($File in $Asm) {
    Send-Member -File $File -Dsn "$Hlq.QUEUE.ASM"
}

$Csrc = @(Get-ChildItem -LiteralPath $Test -File -Filter '*.c')
$Hsrc = @(Get-ChildItem -LiteralPath $Test -File -Filter '*.h')
if (-not $Csrc -and -not $Hsrc) {
    throw "No .c or .h files in $Test"
}
foreach ($File in $Csrc) {
    Send-Member -File $File -Dsn "$Hlq.QUEUE.C"
}
foreach ($File in $Hsrc) {
    Send-Member -File $File -Dsn "$Hlq.QUEUE.H"
}

Write-Host ''
Write-Host ("Done. {0} ASM, {1} C, {2} H." -f @($Asm).Count, $Csrc.Count, $Hsrc.Count)
Write-Host 'Submit jcl/test_go.jcl when you want to compile and run.'
