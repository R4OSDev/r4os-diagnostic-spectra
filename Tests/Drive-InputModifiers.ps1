param(
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][ValidateRange(1,65535)][int]$QmpPort,
    [switch]$ResyncOnly,
    [switch]$OverlapOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($ResyncOnly -and $OverlapOnly){throw 'Select one explicit input case mode'}
$EvidenceRoot=[IO.Path]::GetFullPath($EvidenceRoot)
$serial=Join-Path $EvidenceRoot 'serial.log'
$proofPath=Join-Path $EvidenceRoot 'host-proof.json'
if(Test-Path -LiteralPath $proofPath){throw 'Never overwrite input evidence'}
$proof=[ordered]@{schema=1;result='failed';event_count=0;holds=@();overlaps=@();duplicate_make_requests=0;fill_presses=$(if($OverlapOnly){0}else{140});all_keys_released=$false;resync_only=$ResyncOnly.IsPresent;overlap_only=$OverlapOnly.IsPresent}
$qmpClient=$null;$reader=$null;$writer=$null;$identity=0
$downKeys=[Collections.Generic.HashSet[string]]::new()
function Read-Serial {
    if(!(Test-Path -LiteralPath $serial)){return ''}
    $stream=[IO.File]::Open($serial,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $textReader=[IO.StreamReader]::new($stream)
    try{$textReader.ReadToEnd()}finally{$textReader.Dispose();$stream.Dispose()}
}
function Wait-Marker([string]$Marker,[int]$Milliseconds=12000){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt $Milliseconds){
        $text=Read-Serial
        if($text -match 'KERNEL FATAL|Rust panic|\[CRASH\]|SPECTRA INPUT modifiers result: FAILED'){throw ('Guest failed before '+$Marker)}
        if($text.Contains($Marker)){return}
        Start-Sleep -Milliseconds 20
    }
    throw ('Marker deadline: '+$Marker)
}
function Invoke-Qmp([string]$Command,[hashtable]$Arguments=@{}){
    $script:identity++
    $id=$script:identity
    $writer.WriteLine((@{execute=$Command;arguments=$Arguments;id=$id}|ConvertTo-Json -Depth 12 -Compress))
    while($true){
        $line=$reader.ReadLine()
        if($null -eq $line){throw 'QMP closed before acknowledgment'}
        $reply=$line|ConvertFrom-Json -AsHashtable
        if(!$reply.ContainsKey('id') -or $reply.id -ne $id){continue}
        if($reply.ContainsKey('error')){throw ('QMP: '+$reply.error.desc)}
        return
    }
}
function Send-Key([string]$Code,[bool]$Down){
    Invoke-Qmp 'input-send-event' @{events=@(@{type='key';data=@{down=$Down;key=@{type='qcode';data=$Code}}})}
    $proof.event_count++
    if($Down){$null=$downKeys.Add($Code)}else{$null=$downKeys.Remove($Code)}
}
function Press-Key([string]$Code,[int]$Delay=20){
    Send-Key $Code $true
    Start-Sleep -Milliseconds $Delay
    Send-Key $Code $false
}
try{
    Wait-Marker $(if($OverlapOnly){'SPECTRA INPUT modifiers SHIFT_LR READY'}elseif($ResyncOnly){'SPECTRA INPUT modifiers RESET_FILL READY'}else{'SPECTRA INPUT modifiers CTRL READY'}) 120000
    $qmpClient=[Net.Sockets.TcpClient]::new()
    $qmpClient.NoDelay=$true;$qmpClient.ReceiveTimeout=5000;$qmpClient.SendTimeout=5000
    $qmpClient.Connect('127.0.0.1',$QmpPort)
    $network=$qmpClient.GetStream();$utf8=[Text.UTF8Encoding]::new($false)
    $reader=[IO.StreamReader]::new($network,$utf8,$false,4096,$true)
    $writer=[IO.StreamWriter]::new($network,$utf8,4096,$true)
    $writer.NewLine="`n";$writer.AutoFlush=$true
    $greeting=$reader.ReadLine()|ConvertFrom-Json -AsHashtable
    if(!$greeting.ContainsKey('QMP')){throw 'Missing QMP greeting'}
    Invoke-Qmp 'qmp_capabilities'
    if($OverlapOnly){
        foreach($phase in @(
            @{label='SHIFT_LR';first='shift';second='shift_r'},
            @{label='SHIFT_RL';first='shift_r';second='shift'},
            @{label='CTRL_LR';first='ctrl';second='ctrl_r'},
            @{label='CTRL_RL';first='ctrl_r';second='ctrl'}
        )){
            Wait-Marker ('SPECTRA INPUT modifiers '+$phase.label+' READY')
            Send-Key $phase.first $true
            Send-Key $phase.second $true
            Send-Key $phase.second $true
            $proof.duplicate_make_requests++
            Send-Key $phase.first $false
            Press-Key 'a'
            Send-Key $phase.second $false
            Press-Key 'a'
            Wait-Marker ('SPECTRA INPUT modifiers '+$phase.label+': ok')
            $proof.overlaps+=@{label=$phase.label;remaining_side_then_full_release=$true}
        }
    }else{
    if(!$ResyncOnly){foreach($phase in @(
        @{label='CTRL';modifier='ctrl';first='a';second='d';ordinary='a'},
        @{label='ALT';modifier='alt';first='tab';second='tab';ordinary='tab'},
        @{label='ALTGR';modifier='alt_r';first='q';second='q';ordinary='q'}
    )){
        Wait-Marker ('SPECTRA INPUT modifiers '+$phase.label+' READY')
        $hold=[Diagnostics.Stopwatch]::StartNew()
        Send-Key $phase.modifier $true
        Press-Key $phase.first
        Start-Sleep -Milliseconds 1050
        Press-Key $phase.second
        Send-Key $phase.modifier $false
        $heldMs=$hold.ElapsedMilliseconds
        if($heldMs -lt 1050){throw 'Host did not hold the modifier long enough'}
        Press-Key $phase.ordinary
        Wait-Marker ('SPECTRA INPUT modifiers '+$phase.label+': ok')
        $proof.holds+=@{label=$phase.label;held_ms=$heldMs;before_after_release=$true}
    }}
    Wait-Marker 'SPECTRA INPUT modifiers RESET_FILL READY'
    Send-Key 'ctrl' $true
    for($i=0;$i -lt 140;$i++){
        Press-Key 'a' 1
        Start-Sleep -Milliseconds 1
    }
    Press-Key 'ret'
    Wait-Marker 'SPECTRA INPUT modifiers RESET_TAIL READY'
    # Keep Ctrl physically held: only the confirmed resync may clear it.
    Press-Key 'a'
    Wait-Marker 'SPECTRA INPUT modifiers RESET_ACK READY'
    Send-Key 'ctrl' $false
    Press-Key 'ret'
    }
    Wait-Marker 'SPECTRA INPUT modifiers result: OK'
    if($OverlapOnly){
        $text=Read-Serial
        foreach($row in $proof.overlaps){
            $match=[regex]::Match($text,('SPECTRA INPUT modifiers '+[regex]::Escape($row.label)+' modifier-repeats=(\d+)'))
            if(!$match.Success){throw 'Missing guest repeat observation'}
            $row.guest_modifier_repeats=[int]$match.Groups[1].Value
        }
    }
    $expectedEvents=if($OverlapOnly){36}elseif($ResyncOnly){288}else{312}
    if($downKeys.Count -ne 0 -or $proof.event_count -ne $expectedEvents){throw 'Incomplete bounded input sequence'}
    $proof.all_keys_released=$true;$proof.result='pass'
}catch{
    $proof.error=$_.Exception.Message
}finally{
    if($proof.result -cne 'pass' -and $null -ne $writer){
        foreach($key in @('ctrl','ctrl_r','shift','shift_r','alt','alt_r','a','d','q','tab','ret')){
            try{Send-Key $key $false}catch{break}
        }
    }
    if($null -ne $writer){$writer.Dispose()}
    if($null -ne $reader){$reader.Dispose()}
    if($null -ne $qmpClient){$qmpClient.Dispose()}
    [IO.File]::WriteAllText($proofPath,(($proof|ConvertTo-Json -Depth 6)+"`n"),[Text.UTF8Encoding]::new($false))
}
Write-Host ('Bounded QMP PS/2 modifier sequence: '+$proof.result)
if($proof.result -cne 'pass'){exit 1}
