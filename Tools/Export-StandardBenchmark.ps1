param([Parameter(Mandatory)][string]$GuestRecords,[Parameter(Mandatory)][string]$Context,[Parameter(Mandatory)][string]$Output,[string]$Reference,[switch]$SelfReference)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'StandardBenchmark.ps1')
if($Reference -and $SelfReference){throw 'Select an existing reference or an explicit new self-reference.'}
$metadata=Get-Content -Raw -LiteralPath $Context|ConvertFrom-Json -AsHashtable
try{$run=ConvertTo-SpectraRun $GuestRecords $metadata}
catch{
 $run=New-SpectraFailure $metadata $_.Exception.Message $GuestRecords
 Write-SpectraRun $run $Output
 Write-Error ('Incomplete Spectra result exported: '+$Output+'; '+$_.Exception.Message) -ErrorAction Continue
 exit 1
}
$baseline=if($SelfReference){$run}elseif($Reference){Get-Content -Raw -LiteralPath $Reference|ConvertFrom-Json -AsHashtable}else{$null}
Set-SpectraScores $run $baseline
Write-SpectraRun $run $Output
foreach($score in $run.scores){
 Write-Host ($score.area_id+' score='+$(if($null -ne $score.score){$score.score}else{'null ('+$score.reason+')'}))
}
Write-Host ('Spectra run '+$run.run_id+' exported: '+[IO.Path]::GetFullPath($Output))
if($run.status -cne 'completed'){exit 1}
