param(
    [Parameter(Mandatory = $true)][string]$Emu,
    [Parameter(Mandatory = $true)][string]$Boot,
    [Parameter(Mandatory = $true)][string]$Kernel,
    [Parameter(Mandatory = $true)][string]$Sdcard,
    [Parameter(Mandatory = $true)][string]$Gif,
    [Parameter(Mandatory = $true)][string]$Keys
)

$ErrorActionPreference = 'Stop'

Remove-Item -LiteralPath $Gif -ErrorAction SilentlyContinue

$env:SDL_VIDEODRIVER = 'dummy'
$env:SDL_AUDIODRIVER = 'dummy'

$emuDir = Split-Path -Parent $Emu
$env:PATH = "$emuDir;C:\msys64\mingw64\bin;C:\msys64\usr\bin;$env:PATH"

function Quote-Arg([string]$s) {
    if ($s -notmatch '[\s"]') {
        return $s
    }
    return '"' + ($s -replace '"', '\"') + '"'
}

$argv = @(
    '-boot', $Boot,
    '-load', "F00000,$Kernel",
    '-sdcard', $Sdcard,
    '-autokeys', "$Keys\n",
    '-warp',
    '-gif', $Gif
)
$args = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '

$p = Start-Process -FilePath $Emu `
    -WorkingDirectory $emuDir `
    -ArgumentList $args `
    -PassThru `
    -WindowStyle Hidden
Start-Sleep -Seconds 18
if (!$p.HasExited) {
    Stop-Process -Id $p.Id -Force
}

if (!(Test-Path -LiteralPath $Gif)) {
    exit 2
}
