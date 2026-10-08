param(
  [Parameter(Mandatory=$true)][string]$Path,
  [ValidateRange(1,1000)][int]$Lines=12,
  [ValidateRange(1024,1048576)][int]$MaxBytes=16384
)
# Get-Content -Tail can race a rapidly growing Windows log and emit huge output.
# Snapshot Length once, read at most MaxBytes with shared access, and close.
$stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::Open,
  [IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
try {
  $size=$stream.Length
  $header=[byte[]]::new(2);$null=$stream.Read($header,0,2)
  $utf16=$header[0] -eq 255 -and $header[1] -eq 254
  $encoding=if($utf16){[Text.Encoding]::Unicode}else{[Text.Encoding]::UTF8}
  $start=[Math]::Max(0,$size-$MaxBytes)
  if($utf16 -and $start%2){$start++}
  $null=$stream.Seek($start,[IO.SeekOrigin]::Begin)
  $buffer=[byte[]]::new([int]($size-$start));$received=0
  while($received -lt $buffer.Length){
    $count=$stream.Read($buffer,$received,$buffer.Length-$received)
    if(!$count){break};$received+=$count
  }
  $text=$encoding.GetString($buffer,0,$received)
  $rows=$text -split '\r?\n'
  if($start -gt 0){$rows=$rows | Select-Object -Skip 1}
  $rows | Where-Object {$_ -ne ''} | Select-Object -Last $Lines
} finally {$stream.Dispose()}
