# Upload HLASM source to Z72675.QUEUE.ASM and macros/copybooks to Z72675.QUEUE.MAC.
# Member name is the file basename, uppercased, 1-8 characters.
# Does not submit a job.
param(
    [string]$Hlq = 'Z72675'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $Root 'src'
if (-not (Test-Path -LiteralPath $Src)) {
    throw "Source directory not found: $Src"
}

$AsmDsn = "$Hlq.QUEUE.ASM"
$MacDsn = "$Hlq.QUEUE.MAC"

$Files = Get-ChildItem -LiteralPath $Src -File | Where-Object {
    $_.Extension -match '^\.(asm|mac|inc)$'
}
if (-not $Files) {
    throw "No .asm, .mac, or .inc files in $Src"
}

foreach ($File in $Files) {
    $Member = $File.BaseName.ToUpperInvariant()
    if ($Member.Length -lt 1 -or $Member.Length -gt 8) {
        throw "Member name must be 1-8 characters: $($File.Name)"
    }
    if ($Member -notmatch '^[A-Z@#$][A-Z0-9@#$]{0,7}$') {
        throw "Member name is not a PDS name: $Member"
    }

    if ($File.Extension -eq '.asm') {
        $Dsn = $AsmDsn
    } else {
        $Dsn = $MacDsn
    }

    $Target = "${Dsn}($Member)"
    Write-Host "Upload $($File.Name) -> $Target"
    & zowe files upload file-to-data-set $File.FullName $Target --migrated-recall wait --response-timeout 180
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$AsmCount = @($Files | Where-Object { $_.Extension -eq '.asm' }).Count
$MacCount = @($Files | Where-Object { $_.Extension -eq '.mac' }).Count
$IncCount = @($Files | Where-Object { $_.Extension -eq '.inc' }).Count
Write-Host ''
Write-Host ("Done. {0} ASM, {1} MAC, {2} INC." -f $AsmCount, $MacCount, $IncCount)
