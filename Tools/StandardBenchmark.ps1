# Spectra owns the offline result contract and reference calculation.
$script:SpectraAreas=@('scheduler_sync','memory','ipc','lifecycle','filesystem_io')
$script:SpectraOperations=@('128','8','128','4','8')
$script:SpectraBytes=@('0','1048576','3072','0','1048576')
$script:SpectraWorkloads=[ordered]@{scheduler_sync='notification-roundtrip-128-v1';memory='demand-vm-8x128k-v1';ipc='kernel-dns-status-128-v1';lifecycle='owned-fixture-4-v1';filesystem_io='ntfs-stream-8x64k-v1'}
$script:SpectraSuite='spectra-standard-1'
$script:SpectraScoring='spectra-geomean-1'
$script:SpectraInvariant=[Globalization.CultureInfo]::InvariantCulture
function Get-SpectraCanonical($Value) {
 if($null -eq $Value){return 'null'}
 if($Value -is [Collections.IDictionary]){
  [string[]]$keys=@($Value.Keys);[Array]::Sort($keys,[StringComparer]::Ordinal)
  $parts=foreach($key in $keys){($key|ConvertTo-Json -Compress)+':'+(Get-SpectraCanonical $Value[$key])}
  return '{'+($parts -join ',')+'}'
 }
 if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){
  return '['+(@(foreach($item in $Value){Get-SpectraCanonical $item}) -join ',')+']'
 }
 return ($Value|ConvertTo-Json -Compress -Depth 32)
}
function Get-SpectraU64($Value,[switch]$Nullable) {
 if($null -eq $Value -and $Nullable){return $null}
 if($Value -isnot [string] -or $Value -cnotmatch '^(0|[1-9][0-9]*)$'){throw 'A uint64 field must be a lossless decimal string.'}
 return [uint64]::Parse($Value,$script:SpectraInvariant)
}
function Get-SpectraDecimal($Value) {
 if($Value -isnot [string] -or $Value -cnotmatch '^[0-9]+(\.[0-9]+)?$'){throw 'Invalid finite decimal quantity.'}
 return [decimal]::Parse($Value,$script:SpectraInvariant)
}
function Get-SpectraQuantity([uint64]$Elapsed,[uint64]$Operations) {
 if($Operations -eq 0){throw 'Zero operation count.'}
 $value=[decimal]::Truncate(([decimal]$Elapsed/[decimal]$Operations)*1000000)/1000000
 return $value.ToString('0.000000',$script:SpectraInvariant)
}
function Get-SpectraMetricUsable($Metric) {
 try {
  if($Metric.status -cne 'ok' -or !$Metric.primary -or $Metric.metric_version -cne '1' -or $Metric.unit -cne 'ns/operation' -or
     $Metric.direction -cne 'lower_is_better' -or (Get-SpectraDecimal $Metric.weight) -ne 1 -or
     (Get-SpectraU64 $Metric.sample_count) -ne 5 -or (Get-SpectraDecimal $Metric.median_value) -le 0){return $false}
  foreach($name in @('work_complete','clock_valid','cleanup_confirmed')){if($Metric.checks[$name] -isnot [bool] -or !$Metric.checks[$name]){return $false}}
  return $true
 }catch{return $false}
}
function Get-SpectraComparisonReason($Run,$Reference) {
 try {
 $null=[guid]::Parse($Reference.run_id)
 if($Reference.schema_version -ne 1 -or $Reference.status -cne 'completed' -or [string]$Reference.run_id -notmatch '^[0-9a-fA-F-]{36}$'){return 'reference-incomplete-or-invalid'}
 foreach($key in @('suite_version','scoring_version','comparison_key','instrumentation_mode')){
  if(!$Run[$key] -or $Run[$key] -cne $Reference[$key]){return 'incompatible-'+$key}
 }
 foreach($key in @('execution','vcpus','ram_bytes','qemu','storage','workloads','cache_state','warmup_runs','repetitions')){
  if($null -eq $Run.environment[$key] -or $null -eq $Reference.environment[$key] -or
     (Get-SpectraCanonical $Run.environment[$key]) -cne (Get-SpectraCanonical $Reference.environment[$key])){return 'incompatible-environment-'+$key}
 }
 if(@($Reference.metrics).Count -ne 5){return 'reference-metrics-incomplete'}
 foreach($area in $script:SpectraAreas){
  $found=@($Reference.metrics|Where-Object {$_.area_id -ceq $area -and $_.metric_id -ceq 'elapsed_ns_per_operation'})
  if($found.Count -ne 1 -or !(Get-SpectraMetricUsable $found[0])){return 'reference-metric-invalid-'+$area}
 }
 return $null
 }catch{return 'reference-invalid-or-incomplete'}
}
function Set-SpectraScores($Run,$Reference) {
 $reason=if($null -eq $Reference){'reference-not-supplied'}else{Get-SpectraComparisonReason $Run $Reference}
 $referenceId=if($Reference -is [Collections.IDictionary]){$Reference['run_id']}else{$null}
 $parsedId=[guid]::Empty
 $Run.baseline_run_id=if($referenceId -and [guid]::TryParse([string]$referenceId,[ref]$parsedId)){$parsedId.ToString()}else{$null}
 $scores=[Collections.Generic.List[object]]::new();$values=[Collections.Generic.List[double]]::new()
 foreach($area in $script:SpectraAreas){
  $current=@($Run.metrics|Where-Object {$_.area_id -ceq $area})
  $why=$reason;$value=$null
  if(!$why -and ($current.Count -ne 1 -or !(Get-SpectraMetricUsable $current[0]))){$why='current-metric-invalid-'+$area}
  if(!$why){
   $base=@($Reference.metrics|Where-Object {$_.area_id -ceq $area})[0]
   $ratio=[decimal]100*(Get-SpectraDecimal $base.median_value)/(Get-SpectraDecimal $current[0].median_value)
   $v=[double]$ratio
   if(![double]::IsFinite($v) -or $v -le 0){$why='invalid-score'}else{$value=$v.ToString('0.000000',$script:SpectraInvariant);$values.Add($v)}
  }
  $scores.Add([ordered]@{area_id=$area;baseline_run_id=$Run.baseline_run_id;scoring_version=$script:SpectraScoring;score=$value;status=$(if($value){'valid'}else{'unavailable'});reason=$why})
 }
 $total=$null;$why=$reason
 if(!$why -and $Run.status -ceq 'completed' -and $values.Count -eq 5){
  [double]$sum=0;foreach($v in $values){$sum += [Math]::Log($v/100)}
  $v=100*[Math]::Exp($sum/5)
  if([double]::IsFinite($v) -and $v -gt 0){$total=$v.ToString('0.000000',$script:SpectraInvariant)}
 }
 if(!$total -and !$why){$why='all-five-valid-areas-and-completed-run-required'}
 $scores.Add([ordered]@{area_id='overall';baseline_run_id=$Run.baseline_run_id;scoring_version=$script:SpectraScoring;score=$total;status=$(if($total){'valid'}else{'unavailable'});reason=$why})
 $Run.scores=@($scores.ToArray())
}
function ConvertTo-SpectraRun([string]$GuestRecords,$Context) {
 $records=@(foreach($line in [IO.File]::ReadLines($GuestRecords)){
  if($line.StartsWith('{"schema":"r4os.spectra.standard"')){
   $record=$line|ConvertFrom-Json -AsHashtable
   if($record.schema_version -ne 1){throw 'Unsupported guest result version.'}
   $record
  }
 })
 $headers=@($records|Where-Object {$_.kind -ceq 'header'});$results=@($records|Where-Object {$_.kind -ceq 'result'})
 if($headers.Count -ne 1 -or $results.Count -ne 1){throw 'A complete single guest run is required.'}
 $header=$headers[0];$result=$results[0]
 if($header.suite_version -cne $script:SpectraSuite -or $header.scoring_version -cne $script:SpectraScoring -or
    $header.warmup_runs -cne '1' -or $header.repetitions -cne '5' -or $header.vcpus -cne '4' -or $header.settle_ms -cne '200' -or
    (Get-SpectraCanonical $header.workloads) -cne (Get-SpectraCanonical $script:SpectraWorkloads)){throw 'Guest workload differs from the fixed standard profile.'}
 $run=[ordered]@{}
 foreach($key in @('run_id','host_id','started_at_utc','finished_at_utc','release_version','kernel_version','environment_id','comparison_key','environment','artifacts')){$run[$key]=$Context[$key]}
 if([string]::IsNullOrWhiteSpace($run.host_id) -or !$run.environment -or !$run.artifacts){throw 'Complete host metadata is required.'}
 $null=[guid]::Parse($run.run_id)
 $run.schema_version=1;$run.suite_version=$header.suite_version;$run.scoring_version=$header.scoring_version
 $run.spectra_version=$header.spectra_version;$run.instrumentation_mode=$header.instrumentation_mode
 foreach($artifact in $run.artifacts){if($artifact.component -ceq 'kernel'){$artifact.build_options.metrics=$header.instrumentation_mode -ceq 'detail'}}
 $run.status=$result.status;$run.failure_reason=if($result.status -ceq 'completed'){$null}else{'guest-'+$result.status}
 if($result.status -notin @('completed','failed','cancelled','incomplete') -or
    ($result.status -ceq 'completed' -and $result.exit_code -cne '0') -or
    ($result.status -cin @('failed','cancelled') -and $result.exit_code -ceq '0')){throw 'Invalid terminal guest status.'}
 $run.notes='Fixed kernel workloads; one warmup and five retained samples per area. CPU/host identity is contextual; method compatibility is checked independently. No speed budget.'
 $run.baseline_run_id=$null;$run.metrics=@();$run.samples=@();$run.scores=@()
 $metricRecords=@($records|Where-Object {$_.kind -ceq 'metric'});$sampleRecords=@($records|Where-Object {$_.kind -ceq 'sample'})
 if($metricRecords.Count -ne 5 -or $sampleRecords.Count -ne 30 -or @($records|Where-Object {$_.kind -ceq 'score'}).Count -ne 6 -or $records.Count -ne 43){throw 'Missing, duplicate or unknown guest records.'}
 for($i=0;$i -lt 5;$i++){
  $area=$script:SpectraAreas[$i];$found=@($metricRecords|Where-Object {$_.area_id -ceq $area})
  if($found.Count -ne 1){throw 'Missing/duplicate area metric.'}
  $metric=$found[0].Clone();$metric.Remove('schema');$metric.Remove('schema_version');$metric.Remove('kind')
  if($metric.metric_id -cne 'elapsed_ns_per_operation' -or $metric.metric_version -cne '1' -or $metric.unit -cne 'ns/operation' -or $metric.direction -cne 'lower_is_better' -or $metric.primary -isnot [bool] -or !$metric.primary -or $metric.weight -cne '1'){throw 'Invalid primary metric contract.'}
  $measured=[Collections.Generic.List[uint64]]::new();$allOk=$true
  foreach($phase in @('warmup','measurement')){
   $count=if($phase -ceq 'warmup'){1}else{5}
   for($index=0;$index -lt $count;$index++){
    $selected=@($sampleRecords|Where-Object {$_.area_id -ceq $area -and $_.phase -ceq $phase -and $_.sample_index -ceq [string]$index})
    if($selected.Count -ne 1){throw 'Missing/duplicate raw sample identity.'}
    $sample=$selected[0].Clone();foreach($key in @('schema','schema_version','kind')){$sample.Remove($key)}
    foreach($key in @('sample_index','elapsed_ns','operation_count','bytes_processed','clock_generation','clock_resolution_ns','observer_overhead_ns')){$null=Get-SpectraU64 $sample[$key] -Nullable}
    if($sample.metric_id -cne $metric.metric_id -or $sample.status -notin @('ok','failed','skipped','incomplete')){throw 'Invalid sample status/metric.'}
    if($sample.status -ceq 'ok'){
     $elapsed=Get-SpectraU64 $sample.elapsed_ns;$operations=Get-SpectraU64 $sample.operation_count;$resolution=Get-SpectraU64 $sample.clock_resolution_ns
     if($sample.operation_count -cne $script:SpectraOperations[$i] -or $sample.bytes_processed -cne $script:SpectraBytes[$i] -or
        $elapsed -eq 0 -or $resolution -eq 0 -or [decimal]$elapsed -lt [decimal]$resolution*10 -or $sample.clock_source -notin @('TSC','HPET') -or !(Get-SpectraU64 $sample.clock_generation) -or
        $sample.value -cne (Get-SpectraQuantity $elapsed $operations) -or $null -ne $sample.failure_reason){throw 'Successful sample does not prove its complete work/clock/value.'}
     if($phase -ceq 'measurement'){$measured.Add($elapsed)}
    }else{$allOk=$false}
    $run.samples+=,$sample
   }
  }
  if($metric.status -ceq 'ok'){
   if(!$allOk -or $measured.Count -ne 5 -or !(Get-SpectraMetricUsable $metric)){throw 'Successful metric contains failed/missing raw work.'}
   $sorted=@($measured.ToArray()|Sort-Object);[uint64]$median=$sorted[2]
   $deviations=@(foreach($v in $sorted){if($v -ge $median){$v-$median}else{$median-$v}})|Sort-Object
   $expected=@{median_value=$median;min_value=$sorted[0];max_value=$sorted[4];mad_value=$deviations[2]}
   foreach($key in $expected.Keys){if($metric[$key] -cne (Get-SpectraQuantity $expected[$key] ([uint64]$script:SpectraOperations[$i]))){throw 'Guest metric does not match retained raw samples.'}}
  }elseif($run.status -ceq 'completed'){throw 'Completed run lacks an area.'}
  $run.metrics+=,$metric
 }
 $observed=@($run.samples|Where-Object {$_.status -ceq 'ok'})
 $resolutions=@($observed|ForEach-Object {[uint64]$_.clock_resolution_ns}|Sort-Object)
 $costs=@($observed|Where-Object {$null -ne $_.observer_overhead_ns}|ForEach-Object {[uint64]$_.observer_overhead_ns}|Sort-Object)
 $run.environment.clock=[ordered]@{sources=@($observed|ForEach-Object {$_.clock_source}|Sort-Object -Unique);generations=@($observed|ForEach-Object {$_.clock_generation}|Sort-Object -Unique);observed_samples=[string]$observed.Count;max_resolution_ns=$(if($resolutions.Count){[string]$resolutions[-1]}else{$null});minimum_observer_pair_ns=$(if($costs.Count){[string]$costs[0]}else{$null});observer_cost_method='minimum-of-64-separate-clock-pairs';intervals_validated=($observed.Count -gt 0)}
 return $run
}
function Write-SpectraRun($Run,[string]$Path) {
 $full=[IO.Path]::GetFullPath($Path);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))|Out-Null
 if(Test-Path -LiteralPath $full){throw 'Run exports are immutable; select a new output path.'}
 $temporary=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{[IO.File]::WriteAllText($temporary,($Run|ConvertTo-Json -Depth 32)+"`n",[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$full)}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
function New-SpectraFailure($Context,[string]$Reason,[string]$GuestRecords) {
 $run=[ordered]@{}
 foreach($key in @('run_id','host_id','started_at_utc','finished_at_utc','release_version','kernel_version','environment_id','comparison_key','environment','artifacts')){$run[$key]=$Context[$key]}
 $run.schema_version=1;$run.status='failed';$run.failure_reason=$Reason;$run.spectra_version=$null
 $run.suite_version=$script:SpectraSuite;$run.scoring_version=$script:SpectraScoring;$run.instrumentation_mode=$null
 $run.notes='Incomplete or invalid guest transport; original serial evidence retained. No completed work or score is inferred.'
 $run.metrics=@();$run.samples=@();$run.scores=@();$run.baseline_run_id=$null
 if(Test-Path -LiteralPath $GuestRecords){$run.artifacts+=,@{component='incomplete-guest-records';sha256=(Get-FileHash -LiteralPath $GuestRecords).Hash.ToLowerInvariant();bytes=([IO.FileInfo]$GuestRecords).Length.ToString($script:SpectraInvariant)}}
 Set-SpectraScores $run $null
 return $run
}
