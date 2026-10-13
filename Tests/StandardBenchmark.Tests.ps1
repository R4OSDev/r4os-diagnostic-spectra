# Offline fixtures only: these synthetic records are never API imports.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Tools/StandardBenchmark.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function Copy-Value($Value){return ($Value|ConvertTo-Json -Depth 32|ConvertFrom-Json -AsHashtable)}
$environment=@{execution='qemu';vcpus='4';ram_bytes='1073741824';qemu=@{version='fixture-1';backend='kvm'};storage=@{controller='fixture'};workloads=$script:SpectraWorkloads;cache_state='warm-per-area-1';warmup_runs='1';repetitions='5';cpu=@{model='first'};host=@{label='first'}}
$context=@{run_id='83030000-0000-4000-8000-000000000001';host_id='offline-fixture';started_at_utc='2026-10-13T00:00:00Z';finished_at_utc='2026-10-13T00:00:01Z';release_version='fixture';kernel_version='fixture';environment_id='fixture';comparison_key='fixture-method';environment=$environment;artifacts=@(@{component='kernel';build_options=@{metrics=$null}})}
$records=[Collections.Generic.List[object]]::new()
$records.Add(@{schema='r4os.spectra.standard';schema_version=1;kind='header';suite_version=$script:SpectraSuite;scoring_version=$script:SpectraScoring;spectra_version='fixture';instrumentation_mode='base';cache_state='warm-per-area-1';warmup_runs='1';repetitions='5';vcpus='4';settle_ms='200';workloads=$script:SpectraWorkloads})
for($i=0;$i -lt 5;$i++){
 $area=$script:SpectraAreas[$i];$operations=[uint64]$script:SpectraOperations[$i];$elapsed=($operations*1000000).ToString($script:SpectraInvariant)
 foreach($phase in @('warmup','measurement')){
  $n=if($phase -ceq 'warmup'){1}else{5}
  for($j=0;$j -lt $n;$j++){$records.Add(@{schema='r4os.spectra.standard';schema_version=1;kind='sample';area_id=$area;metric_id='elapsed_ns_per_operation';phase=$phase;sample_index=[string]$j;status='ok';failure_reason=$null;elapsed_ns=$elapsed;operation_count=[string]$operations;bytes_processed=$script:SpectraBytes[$i];value='1000000.000000';clock_source='TSC';clock_generation='1';clock_resolution_ns='1';observer_overhead_ns='10'})}
 }
 $records.Add(@{schema='r4os.spectra.standard';schema_version=1;kind='metric';area_id=$area;metric_id='elapsed_ns_per_operation';metric_version='1';unit='ns/operation';direction='lower_is_better';primary=$true;weight='1';status='ok';failure_reason=$null;sample_count='5';median_value='1000000.000000';min_value='1000000.000000';max_value='1000000.000000';mad_value='0.000000';checks=@{work_complete=$true;clock_valid=$true;cleanup_confirmed=$true}})
 $records.Add(@{schema='r4os.spectra.standard';schema_version=1;kind='score';area_id=$area})
}
$records.Add(@{schema='r4os.spectra.standard';schema_version=1;kind='score';area_id='overall'})
$records.Add(@{schema='r4os.spectra.standard';schema_version=1;kind='result';exit_code='0';status='completed'})
$tempRoot=if($env:R4OS_WORKSPACE_TEMP){$env:R4OS_WORKSPACE_TEMP}else{Join-Path $PSScriptRoot '../../../../Temp'}
$scratch=Join-Path ([IO.Path]::GetFullPath($tempRoot)) ('SpectraContract/'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($scratch)|Out-Null
try{
 $raw=Join-Path $scratch 'synthetic.ndjson'
 function Write-Raw($Items){
  $lines=foreach($item in $Items){$ordered=[ordered]@{schema=$item.schema};foreach($key in $item.Keys){if($key -cne 'schema'){$ordered[$key]=$item[$key]}};$ordered|ConvertTo-Json -Compress -Depth 16}
  [IO.File]::WriteAllLines($raw,[string[]]$lines,[Text.UTF8Encoding]::new($false))
 }
 Write-Raw $records
 $run=ConvertTo-SpectraRun $raw $context
 Set-SpectraScores $run $run
 Assert-True (@($run.scores|Where-Object {$_.score -cne '100.000000'}).Count -eq 0) 'Self reference must have exactly six 100 scores.'
 $reference=Copy-Value $run;$current=Copy-Value $run
 $current.metrics[0].median_value='500000.000000';$current.metrics[1].median_value='2000000.000000'
 Set-SpectraScores $current $reference
 Assert-True ($current.scores[0].score -ceq '200.000000' -and $current.scores[1].score -ceq '50.000000' -and $current.scores[5].score -ceq '100.000000') 'Relative timing and equal area weights failed.'
 $current.environment.cpu.model='second';$current.host_id='other-host';$current.environment_id='other-label'
 Set-SpectraScores $current $reference
 Assert-True ($current.scores[5].score -ceq '100.000000') 'CPU/host identity is contextual, not a method mismatch.'
 $current.status='failed';$current.metrics[2].status='failed';$current.metrics[2].median_value=$null
 Set-SpectraScores $current $reference
 Assert-True ($null -eq $current.scores[2].score -and $null -eq $current.scores[5].score -and $current.scores[0].score -ceq '200.000000') 'Partial results must not reweight the overall score.'
 foreach($case in @('clock','backend','missing','zero','weight')){
  $base=Copy-Value $reference
  switch($case){
   'clock' {$base.instrumentation_mode='detail'}
   'backend' {$base.environment.qemu.backend='tcg'}
   'missing' {$base.metrics=@($base.metrics[0..3])}
   'zero' {$base.metrics[0].median_value='0'}
   'weight' {$base.metrics[0].weight='2'}
  }
  $probe=Copy-Value $run;Set-SpectraScores $probe $base
  Assert-True (@($probe.scores|Where-Object {$null -ne $_.score}).Count -eq 0) ('Invalid reference scored: '+$case)
 }
 $probe=Copy-Value $run;Set-SpectraScores $probe @{}
 Assert-True ($null -eq $probe.scores[5].score) 'Malformed reference must be explicitly unavailable.'
 Assert-True ((Get-SpectraU64 '18446744073709551615') -eq [uint64]::MaxValue) 'Maximum uint64 lost precision.'
 Assert-True ((Get-SpectraQuantity ([uint64]::MaxValue) 128) -ceq '144115188075855871.992187') 'Lossless rational quantity mismatch.'
 $output=Join-Path $scratch 'synthetic.json';Write-SpectraRun $run $output
 $again=Get-Content -Raw $output|ConvertFrom-Json -AsHashtable
 Assert-True ($again.samples[0].elapsed_ns -is [string]) 'Raw counters must remain strings.'
 $rejected=$false;try{Write-SpectraRun $run $output}catch{$rejected=$true};Assert-True $rejected 'Existing run export was overwritten.'
 foreach($case in @('duplicate','truncated','wrong-work','zero-time','bad-clock','aggregate')){
  $items=Copy-Value @($records.ToArray())
  switch($case){
   'duplicate' {$items+=,$items[1]}
   'truncated' {$items=@($items[0..($items.Count-2)])}
   'wrong-work' {$items[1].operation_count='127'}
   'zero-time' {$items[1].elapsed_ns='0'}
   'bad-clock' {$items[1].clock_generation='0'}
   'aggregate' {$items[7].median_value='999999.000000'}
  }
  Write-Raw $items;$rejected=$false;try{$null=ConvertTo-SpectraRun $raw $context}catch{$rejected=$true}
  Assert-True $rejected ('Invalid raw result accepted: '+$case)
 }
 $cancelled=Copy-Value @($records.ToArray())
 foreach($item in $cancelled){
  if($item.kind -ceq 'sample'){
   $item.status='failed';$item.failure_reason='Cancelled';$item.elapsed_ns=$null;$item.operation_count='0';$item.bytes_processed='0';$item.value=$null;$item.clock_source='unavailable';$item.clock_generation=$null;$item.clock_resolution_ns=$null;$item.observer_overhead_ns=$null
  }
  if($item.kind -ceq 'metric'){
   $item.status='failed';$item.failure_reason='Cancelled';$item.sample_count='0';foreach($key in @('median_value','min_value','max_value','mad_value')){$item[$key]=$null};foreach($key in $item.checks.Keys|ForEach-Object {$_}){$item.checks[$key]=$false}
  }
  if($item.kind -ceq 'result'){$item.status='cancelled';$item.exit_code='4'}
 }
 Write-Raw $cancelled;$partial=ConvertTo-SpectraRun $raw $context;Set-SpectraScores $partial $reference
 Assert-True ($partial.status -ceq 'cancelled' -and $partial.samples.Count -eq 30 -and $partial.environment.clock.observed_samples -ceq '0' -and @($partial.scores|Where-Object {$null -ne $_.score}).Count -eq 0) 'Cancellation lost raw evidence or produced a score.'
 Write-Host 'Spectra standard contract: reference/scoring, partial/incompatible/error cases, exact uint64, raw identities, aggregates and immutable export passed.'
}finally{Remove-Item -LiteralPath $scratch -Recurse -Force}
