param([Parameter(Mandatory)][string]$Marker)
# Finds the claude worker process whose command line carries $Marker and dumps its
# full descendant tree (name, pid, private MB, trimmed command line) plus totals.
$all = Get-CimInstance Win32_Process
$roots = $all | Where-Object { $_.CommandLine -like "*$Marker*" -and $_.CommandLine -like '*claude*' -and $_.Name -notmatch '^(bash|powershell|pwsh)' }
if (-not $roots) { "no worker process found for $Marker"; exit 1 }
$root = $roots | Sort-Object CreationDate | Select-Object -First 1
$byParent = $all | Group-Object ParentProcessId -AsHashTable -AsString
$tree = [System.Collections.Generic.List[object]]::new()
function Walk($p, $depth) {
  $tree.Add([pscustomobject]@{ Depth = $depth; Proc = $p })
  $kids = $byParent["$($p.ProcessId)"]
  foreach ($k in $kids) { Walk $k ($depth + 1) }
}
Walk $root 0
"worker root: pid=$($root.ProcessId) name=$($root.Name)"
"root command line flags: " + (([regex]::Matches($root.CommandLine, '--(strict-mcp-config|mcp-config|chrome|dangerously-skip-permissions|disallowedTools)\b') | ForEach-Object Value) -join ' ')
$total = 0
foreach ($t in $tree) {
  $pp = Get-Process -Id $t.Proc.ProcessId -ErrorAction SilentlyContinue
  $mb = if ($pp) { [math]::Round($pp.PrivateMemorySize64 / 1MB, 1) } else { 0 }
  $total += $mb
  $cl = ($t.Proc.CommandLine -replace '\s+', ' ')
  if ($cl.Length -gt 160) { $cl = $cl.Substring(0, 160) + '...' }
  ('  ' * $t.Depth) + "$($t.Proc.Name) pid=$($t.Proc.ProcessId) private=${mb}MB :: $cl"
}
"descendant processes (excluding root): $($tree.Count - 1)"
"total private MB (root + descendants): $total"
