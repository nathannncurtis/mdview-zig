param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string]$Work
)
$ErrorActionPreference = 'Stop'
$Version = $Version.TrimStart('v')
if ($Version -notmatch '^(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})\.(0|[1-9]\d{0,4})$' -or ($Version -split '\.' | Where-Object { [int]$_ -gt 65535 })) {
    throw "version must be three numeric parts up to 65535: $Version"
}
$bin = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*" -Directory | Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path "$($_.FullName)\x64\makeappx.exe" } | Select-Object -First 1).FullName + '\x64'

$layout = Join-Path $Work 'layout'
New-Item -ItemType Directory -Force $layout | Out-Null
Copy-Item $Exe $layout
Copy-Item "$PSScriptRoot\Assets" $layout -Recurse
$xml = (Get-Content "$PSScriptRoot\AppxManifest.xml" -Raw)
if (-not $xml.Contains('__VERSION__')) { throw 'manifest has no __VERSION__' }
[IO.File]::WriteAllText("$layout\AppxManifest.xml", $xml.Replace('__VERSION__', "$Version.0"), [Text.UTF8Encoding]::new($false))

$cfg = Join-Path $Work 'priconfig.xml'
& "$bin\makepri.exe" createconfig /cf $cfg /dq en-US /o
if ($LASTEXITCODE) { throw 'makepri createconfig failed' }
& "$bin\makepri.exe" new /pr $layout /cf $cfg /mn "$layout\AppxManifest.xml" /of "$layout\resources.pri" /o
if ($LASTEXITCODE) { throw 'makepri new failed' }
& "$bin\makeappx.exe" pack /d $layout /p $Output /o
if ($LASTEXITCODE) { throw 'makeappx pack failed' }
