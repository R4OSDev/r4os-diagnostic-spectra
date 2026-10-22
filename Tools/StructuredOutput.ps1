# Strict file NDJSON framing. Owner JSON values remain untouched; this is not
# the separate STANDARD export/scoring model or a serial-prefix repair path.
function Read-SpectraStructuredOutput {
 param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
 if($Text.Length -gt 8MB){throw 'Spectra structured output exceeds its bounded file size.'}
 $records=[Collections.Generic.List[object]]::new()
 foreach($line in $Text.Split("`n")){
  if(!$line.Trim()){continue}
  $record=$line|ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop
  if($record -isnot [Collections.IDictionary] -or $record.schema -cne 'r4os.spectra' -or
   ($record.schema_version -isnot [long] -and $record.schema_version -isnot [int]) -or $record.schema_version -ne 1 -or
   $record.kind -isnot [string] -or !$record.kind -or $record.group -isnot [string] -or !$record.group -or
   !$record.Contains('data') -or !$record.Contains('detail_enabled')){throw 'Invalid current Spectra record.'}
  foreach($field in @('index','snapshot')){
   $recordIndex=[ulong]0
   if($record[$field] -isnot [string] -or $record[$field] -cnotmatch '^(0|[1-9][0-9]*)$' -or
    ![ulong]::TryParse($record[$field],[ref]$recordIndex)){throw 'Invalid Spectra record index.'}
  }
  if($null -ne $record.detail_enabled -and $record.detail_enabled -isnot [bool]){throw 'Invalid Spectra detail metadata.'}
  $records.Add($record)
 }
 return ,@($records.ToArray())
}
function Get-SpectraScalar($Value) {
 if($Value -is [Collections.IDictionary] -and ($Value.Contains('value') -or $Value.Contains('unit'))){
  if($Value.Count -ne 2 -or !$Value.Contains('value') -or $Value.unit -isnot [string]){throw 'Invalid Spectra quantified scalar.'}
  return $Value.value
 }
 return $Value
}
