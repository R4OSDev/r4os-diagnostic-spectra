param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A disposable derivative of the existing Windows NTFS4K reference. Exact
# source identity makes these small, fixed record edits intentional; this is
# not a general NTFS editor and never changes the reference archive.
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$archive = Join-Path $workspace 'Repositories/SDK/Tests/Fixture/Ntfs/NtfsFixtures0603.zip'
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw 'Fixture destination already exists' }
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $stream = $zip.GetEntry('NTFS4K.img').Open()
    $memory = [IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); [byte[]]$image = $memory.ToArray() }
    finally { $stream.Dispose(); $memory.Dispose() }
} finally { $zip.Dispose() }
$original = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($image)).ToLowerInvariant()
if ($original -cne 'e2cec54385f6170530d3a1c4d8ff21919a8f5964a67407289477579088927e63') { throw 'Unexpected NTFS4K reference' }

function U16([byte[]]$Data, [int]$Offset) { [BitConverter]::ToUInt16($Data, $Offset) }
function U32([byte[]]$Data, [int]$Offset) { [BitConverter]::ToUInt32($Data, $Offset) }
function U64([byte[]]$Data, [int]$Offset) { [BitConverter]::ToUInt64($Data, $Offset) }
function Put16([byte[]]$Data, [int]$Offset, [uint16]$Value) { [BitConverter]::GetBytes($Value).CopyTo($Data, $Offset) }
function Put64([byte[]]$Data, [int]$Offset, [uint64]$Value) { [BitConverter]::GetBytes($Value).CopyTo($Data, $Offset) }
$partition = [int](U32 $image 454) * 512
$cluster = [int](U16 $image ($partition + 11)) * [int]$image[$partition + 13]
$mft = $partition + [int](U64 $image ($partition + 48)) * $cluster
if ($partition -ne 65536 -or $cluster -ne 4096 -or $mft -ne 10878976 -or $image[$partition + 64] -ne 246) { throw 'Unexpected reference geometry' }

function Read-Record([int]$Number, [string]$Name) {
    $start = $mft + $Number * 1024
    [byte[]]$record = $image[$start..($start + 1023)]
    if ([Text.Encoding]::ASCII.GetString($record, 0, 4) -cne 'FILE' -or (U32 $record 44) -ne $Number) { throw 'Wrong MFT record' }
    $usa = U16 $record 4
    if ((U16 $record 6) -ne 3) { throw 'Wrong fixup count' }
    for ($sector = 1; $sector -le 2; $sector++) {
        $tail = $sector * 512 - 2
        if ((U16 $record $tail) -ne (U16 $record $usa)) { throw 'Invalid source fixup' }
        Put16 $record $tail (U16 $record ($usa + $sector * 2))
    }
    $foundName = $false
    $dataOffset = -1
    for ($offset = [int](U16 $record 20); $offset + 8 -le 1024;) {
        $kind = U32 $record $offset
        if ($kind -eq [uint32]::MaxValue) { break }
        $length = [int](U32 $record ($offset + 4))
        if ($length -lt 24 -or $offset + $length -gt 1024) { throw 'Invalid attribute' }
        if ($kind -eq 0x30) {
            $value = $offset + [int](U16 $record ($offset + 20))
            if ([Text.Encoding]::Unicode.GetString($record, $value + 66, [int]$record[$value + 64] * 2) -ceq $Name) { $foundName = $true }
        }
        if ($kind -eq 0x80 -and $record[$offset + 9] -eq 0) {
            if ($dataOffset -ne -1) { throw 'Multiple unnamed attributes' }
            $dataOffset = $offset
        }
        $offset += $length
    }
    if (-not $foundName -or $dataOffset -lt 0) { throw 'Wrong fixture file' }
    @{ bytes = $record; start = $start; data = $dataOffset }
}
function Write-Record($Record) {
    [byte[]]$bytes = $Record.bytes
    $usa = U16 $bytes 4
    for ($sector = 1; $sector -le 2; $sector++) {
        $tail = $sector * 512 - 2
        Put16 $bytes ($usa + $sector * 2) (U16 $bytes $tail)
        Put16 $bytes $tail (U16 $bytes $usa)
    }
    $bytes.CopyTo($image, $Record.start)
}
function Set-Initialized([int]$Number, [string]$Name, [uint64]$Size, [uint64]$Initialized) {
    $record = Read-Record $Number $Name
    if ($record.bytes[$record.data + 8] -ne 1 -or (U64 $record.bytes ($record.data + 48)) -ne $Size) { throw 'Unexpected nonresident attribute' }
    Put64 $record.bytes ($record.data + 56) $Initialized
    Write-Record $record
}

# Keep the original LZNT1 bytes, raw units and sparse runs. Only RANDOM.BIN
# gets a simpler deterministic byte oracle; its original 64-cluster extent
# remains fully mapped, so the compressed reader must use the raw branch.
Set-Initialized 378 'COMPRESS.TXT' 270336 65659
Set-Initialized 380 'RANDOM.BIN' 262144 65659
$random = Read-Record 380 'RANDOM.BIN'
$mapping = $random.data + [int](U16 $random.bytes ($random.data + 32))
if ($random.bytes[$mapping] -ne 0x21 -or $random.bytes[$mapping + 1] -ne 64 -or $random.bytes[$mapping + 4] -ne 0) { throw 'Unexpected raw extent' }
$raw = $partition + [int](U16 $random.bytes ($mapping + 2)) * $cluster
for ($i = 0; $i -lt 262144; $i++) { $image[$raw + $i] = [byte](($i * 7 + 17) -band 255) }

Set-Initialized 374 'SPARSE.BIN' 2097152 1048699
$sparse = Read-Record 374 'SPARSE.BIN'
Put16 $sparse.bytes ($sparse.data + 12) 0x8001
Write-Record $sparse
Set-Initialized 43 'DATA2.BIN' 12345 4219

# A valid file/runlist with an invalid LZNT1 header in its initialized
# prefix. Prefix errors must survive; a wholly uninitialized read is zero.
Set-Initialized 42 'DATA1.BIN' 4096 123
$bad = Read-Record 42 'DATA1.BIN'
Put16 $bad.bytes ($bad.data + 12) 1
Put16 $bad.bytes ($bad.data + 34) 4
$mapping = $bad.data + [int](U16 $bad.bytes ($bad.data + 32))
if ($bad.bytes[$mapping] -ne 0x21 -or $bad.bytes[$mapping + 1] -ne 1) { throw 'Unexpected malformed-stream extent' }
$badStart = $partition + [int](U16 $bad.bytes ($mapping + 2)) * $cluster
$image[$badStart] = 1; $image[$badStart + 1] = 0
Write-Record $bad

# Explicit selection marker: CHECK NTFS /INITIALIZED never mistakes a
# user's ordinary NTFS filesystem or the unchanged reference for this one.
$hello = Read-Record 41 'HELLO.TXT'
if ($hello.bytes[$hello.data + 8] -ne 0) { throw 'Unexpected marker attribute' }
$value = $hello.data + [int](U16 $hello.bytes ($hello.data + 20))
$length = [int](U32 $hello.bytes ($hello.data + 16))
$marker = [Text.Encoding]::ASCII.GetBytes('R4OS-INIT-0847')
if ($length -ne 24) { throw 'Unexpected marker length' }
[Array]::Clear($hello.bytes, $value, $length)
$marker.CopyTo($hello.bytes, $value)
Write-Record $hello

[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath)) | Out-Null
[IO.File]::WriteAllBytes($OutputPath, $image)
$proof = [ordered]@{
    schema = 1; source_sha256 = $original
    fixture_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($image)).ToLowerInvariant()
    disposable = $true; record_numbers = @(41, 42, 43, 374, 378, 380)
    initialized_sizes = @{ lznt1 = 65659; raw = 65659; sparse = 1048699; plain = 4219; malformed = 123 }
}
[IO.File]::WriteAllText($OutputPath + '.json', (($proof | ConvertTo-Json -Depth 5) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Host ('Prepared disposable initialized-length NTFS fixture: ' + $OutputPath)
