# Spectra owns the offline result contract and reference calculation.
$script:SpectraAreas=@('scheduler_sync','memory','ipc','lifecycle','filesystem_io')
$script:SpectraOperations=@('16384','512','16384','32','8')
$script:SpectraBytes=@('0','67108864','393216','0','1048576')
$script:SpectraWorkloads=[ordered]@{scheduler_sync='allcpu-notification-ready-roundtrip-16384-v3';memory='allcpu-demand-vm-512x128k-v3';ipc='allcpu-kernel-dns-status-16384-v3';lifecycle='allcpu-owned-fixture-32-v3';filesystem_io='allcpu-ntfs-stream-8x64k-v3'}
$script:SpectraSuite='spectra-standard-3'
$script:SpectraScoring='spectra-geomean-1'
$script:SpectraInvariant=[Globalization.CultureInfo]::InvariantCulture
function Get-SpectraReferenceFingerprint($Run) {
 if($Run.schema_version -ne 1 -or $Run.status -cne 'completed' -or @($Run.metrics).Count -ne 5){throw 'Reference must contain five completed metrics.'}
 $metrics=@(foreach($area in $script:SpectraAreas){
  $found=@($Run.metrics|Where-Object {$_.area_id -ceq $area})
  if($found.Count -ne 1 -or !(Get-SpectraMetricUsable $found[0])){throw ('Invalid reference metric: '+$area)}
  $metric=$found[0].Clone();$metric.Remove('run_id')
  foreach($key in @('weight','median_value','min_value','max_value','mad_value')){
   $metric[$key]=(Get-SpectraDecimal $metric[$key]).ToString('0.############################',$script:SpectraInvariant)
  }
  $metric
 })
 $contract=[ordered]@{run_id=$Run.run_id;suite_version=$Run.suite_version;scoring_version=$Run.scoring_version;
  comparison_key=$Run.comparison_key;instrumentation_mode=$Run.instrumentation_mode;environment=$Run.environment;metrics=$metrics}
 $bytes=[Text.Encoding]::UTF8.GetBytes((Get-SpectraCanonical $contract))
 return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
function Resolve-SpectraReference([string]$Descriptor,[string]$CacheRoot,[string]$ApiUrl='') {
 $pin=Get-Content -LiteralPath $Descriptor -Raw|ConvertFrom-Json -AsHashtable
 $id=([guid]::Parse($pin.run_id)).ToString()
 if($pin.schema -ne 1 -or $pin.scoring_sha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid reference descriptor.'}
 $original=Join-Path $CacheRoot ('References/'+$id+'/original.json')
 if(!(Test-Path -LiteralPath $original)){$original=Join-Path $CacheRoot ($id+'/run.json')}
 $cached=Join-Path $CacheRoot ('References/'+$id+'/reference.json')
 $path=if(Test-Path -LiteralPath $original){$original}else{$cached}
 $download=$null
 if(Test-Path -LiteralPath $path){$run=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable}
 else{
  if(!$ApiUrl){throw 'Reference is not cached; configure R4OS_DEVCENTER_API_URL or DEVCENTER_API_URL in Tools/BenchmarkHost.R4S.'}
  $download=Invoke-WebRequest -Method Get -Uri ($ApiUrl.TrimEnd('/')+'/api/v1/benchmark-runs/'+$id) -TimeoutSec 30
  $run=$download.Content|ConvertFrom-Json -AsHashtable
 }
 if($run.run_id -cne $id -or $run.suite_version -cne $pin.suite_version -or $run.scoring_version -cne $pin.scoring_version -or
    (Get-SpectraReferenceFingerprint $run) -cne $pin.scoring_sha256){throw 'Cached/downloaded reference differs from its frozen scoring contract.'}
 if($path -ceq $original -and (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $pin.original_export_sha256){throw 'Original reference export was modified.'}
 if($download){
  [IO.Directory]::CreateDirectory((Split-Path $cached -Parent))|Out-Null
  [IO.File]::WriteAllText($cached,$download.Content,[Text.UTF8Encoding]::new($false))
 }
 return $path
}
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
  if($Metric.status -cne 'ok' -or !$Metric.primary -or $Metric.metric_version -cnotin @('1','2') -or $Metric.unit -cne 'ns/operation' -or
     $Metric.direction -cne 'lower_is_better' -or (Get-SpectraDecimal $Metric.weight) -ne 1 -or
     (Get-SpectraU64 $Metric.sample_count) -ne 5 -or (Get-SpectraDecimal $Metric.median_value) -le 0){return $false}
  foreach($name in @('work_complete','clock_valid','cleanup_confirmed')){if($Metric.checks[$name] -isnot [bool] -or !$Metric.checks[$name]){return $false}}
  return $true
 }catch{return $false}
}
# Suite 3 measures aggregate throughput with one equal-work participant per
# available CPU. Hardware, CPU count, RAM and native/VM execution are measured
# variables; only the workload/measurement protocol forms the comparison key.
function Get-SpectraMethod($Environment) {
 $fields=@('cpu_policy','measurement','filesystem','workloads','cache_state','warmup_runs','warmup_min_ns','warmup_min_batches','repetitions','settle_ms')
 $method=[ordered]@{suite_version=$script:SpectraSuite;scoring_version=$script:SpectraScoring;metric_version='2'}
 foreach($key in $fields){
  if($null -eq $Environment[$key]){throw ('Incomplete Suite-3 method: '+$key)}
  $method[$key]=$Environment[$key]
 }
 if($method.cpu_policy -cne 'all-available-v1' -or $method.measurement -cne 'parallel-wall-ns-per-operation-v3' -or $method.filesystem -cne 'ntfs'){throw 'Unexpected Suite-3 CPU/measurement/filesystem policy.'}
 return $method
}
function Get-SpectraComparisonReason($Run,$Reference) {
 try {
 $null=[guid]::Parse($Reference.run_id)
 if($Reference.schema_version -ne 1 -or $Reference.status -cne 'completed' -or [string]$Reference.run_id -notmatch '^[0-9a-fA-F-]{36}$'){return 'reference-incomplete-or-invalid'}
 foreach($key in @('suite_version','scoring_version','comparison_key','instrumentation_mode')){
  if(!$Run[$key] -or $Run[$key] -cne $Reference[$key]){return 'incompatible-'+$key}
 }
 if((Get-SpectraCanonical (Get-SpectraMethod $Run.environment)) -cne (Get-SpectraCanonical (Get-SpectraMethod $Reference.environment))){return 'incompatible-workload-method'}
 if(@($Reference.metrics).Count -ne 5){return 'reference-metrics-incomplete'}
 foreach($area in $script:SpectraAreas){
  $found=@($Reference.metrics|Where-Object {$_.area_id -ceq $area -and $_.metric_id -ceq 'elapsed_ns_per_operation'})
  if($found.Count -ne 1 -or $found[0].metric_version -cne '2' -or !(Get-SpectraMetricUsable $found[0])){return 'reference-metric-invalid-'+$area}
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
    $header.warmup_runs -cne '1' -or $header.warmup_min_ns -cne '1000000000' -or $header.warmup_min_batches -cne '3' -or
    $header.cache_state -cne 'parallel-active-per-area-1s-3batches-v3' -or $header.repetitions -cne '5' -or $header.cpu_policy -cne 'all-available-v1' -or $header.settle_ms -cne '200' -or
    (Get-SpectraCanonical $header.workloads) -cne (Get-SpectraCanonical $script:SpectraWorkloads)){throw 'Guest workload differs from the fixed standard profile.'}
 $workers=Get-SpectraU64 $header.vcpus
 if($workers -eq 0 -or $header.worker_count -cne $header.vcpus -or $Context.environment.vcpus -cne $header.vcpus -or $Context.environment.cpu_policy -cne $header.cpu_policy){throw 'Host and guest disagree on complete available CPU participation.'}
 $null=Get-SpectraMethod $Context.environment
 foreach($key in @('cache_state','warmup_runs','warmup_min_ns','warmup_min_batches','repetitions')){
  if($Context.environment[$key] -cne $header[$key]){throw ('Host and guest disagree on '+$key)}
 }
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
 $run.notes='Suite 3: active warmup accumulates at least one second and three fixed batches per area; five fixed longer measurement batches. Scheduler peer readiness precedes timing. All available CPUs participate with equal per-CPU work; wall time is divided by total completed operations. All warmup work retained. No speed budget.'
 $run.baseline_run_id=$null;$run.metrics=@();$run.samples=@();$run.scores=@()
 $metricRecords=@($records|Where-Object {$_.kind -ceq 'metric'});$sampleRecords=@($records|Where-Object {$_.kind -ceq 'sample'})
 if($metricRecords.Count -ne 5 -or $sampleRecords.Count -ne 30 -or @($records|Where-Object {$_.kind -ceq 'score'}).Count -ne 6 -or $records.Count -ne 43){throw 'Missing, duplicate or unknown guest records.'}
 for($i=0;$i -lt 5;$i++){
  $area=$script:SpectraAreas[$i];$found=@($metricRecords|Where-Object {$_.area_id -ceq $area})
  if($found.Count -ne 1){throw 'Missing/duplicate area metric.'}
  $metric=$found[0].Clone();$metric.Remove('schema');$metric.Remove('schema_version');$metric.Remove('kind')
  if($metric.metric_id -cne 'elapsed_ns_per_operation' -or $metric.metric_version -cne '2' -or $metric.unit -cne 'ns/operation' -or $metric.direction -cne 'lower_is_better' -or $metric.primary -isnot [bool] -or !$metric.primary -or $metric.weight -cne '1'){throw 'Invalid primary metric contract.'}
  $measured=[Collections.Generic.List[uint64]]::new();$allOk=$true
  foreach($phase in @('warmup','measurement')){
   $count=if($phase -ceq 'warmup'){1}else{5}
   for($index=0;$index -lt $count;$index++){
    $selected=@($sampleRecords|Where-Object {$_.area_id -ceq $area -and $_.phase -ceq $phase -and $_.sample_index -ceq [string]$index})
    if($selected.Count -ne 1){throw 'Missing/duplicate raw sample identity.'}
    $sample=$selected[0].Clone();foreach($key in @('schema','schema_version','kind')){$sample.Remove($key)}
    foreach($key in @('sample_index','elapsed_ns','operation_count','bytes_processed','clock_generation','clock_resolution_ns','observer_overhead_ns','worker_count','completed_workers')){$null=Get-SpectraU64 $sample[$key] -Nullable}
    if($sample.metric_id -cne $metric.metric_id -or $sample.status -notin @('ok','failed','skipped','incomplete')){throw 'Invalid sample status/metric.'}
    if($sample.status -ceq 'ok'){
     $elapsed=Get-SpectraU64 $sample.elapsed_ns;$operations=Get-SpectraU64 $sample.operation_count;$resolution=Get-SpectraU64 $sample.clock_resolution_ns
     $batchOperations=[uint64]$script:SpectraOperations[$i]*$workers;$batchBytes=[uint64]$script:SpectraBytes[$i]*$workers
     $workValid=if($phase -ceq 'warmup'){
      $operations -ge 3*$batchOperations -and $operations % $batchOperations -eq 0 -and $elapsed -ge 1000000000 -and
      [decimal]$sample.bytes_processed -eq [decimal]$batchBytes*([decimal]$operations/[decimal]$batchOperations)
     }else{[uint64]$sample.operation_count -eq $batchOperations -and [uint64]$sample.bytes_processed -eq $batchBytes}
     if(!$workValid -or $sample.worker_count -cne $header.vcpus -or $sample.completed_workers -cne $header.vcpus -or
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
   foreach($key in $expected.Keys){if($metric[$key] -cne (Get-SpectraQuantity $expected[$key] ([uint64]$script:SpectraOperations[$i]*$workers))){throw 'Guest metric does not match retained raw samples.'}}
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
