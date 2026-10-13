# Opt-in capture. No settings, visibility, physics or frame caps are changed.
# Run from PowerShell: .\Profile-Windows.ps1
$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$folder = Join-Path $PSScriptRoot "performance-$stamp"
New-Item -ItemType Directory -Path $folder | Out-Null
$frames = Join-Path $folder 'frames.csv'
$log = Join-Path $folder 'game.log'
$memory = Join-Path $folder 'memory.csv'
$exe = Join-Path $PSScriptRoot 'Godot Dash.exe'
if (!(Test-Path $exe)) { throw 'Extract the entire Windows ZIP before running this script.' }
$arguments = @('--rendering-method', 'forward_plus', '--log-file', "`"$log`"", '--', '--perf-capture', "`"--perf-output=$frames`"")
$process = Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot -ArgumentList $arguments -PassThru
$clock = [Diagnostics.Stopwatch]::StartNew()
$writer = [IO.StreamWriter]::new($memory, $false)
$writer.WriteLine('elapsed_ms,utc,working_set_bytes,private_bytes,peak_working_set_bytes')
Write-Host 'Open one slow level, then play OR edit it. Capture starts after 120 active frames.'
Write-Host 'Keep the same level, camera route, resolution, settings and frame cap for comparisons.'
Write-Host 'After 1800 frames, frames.csv is written; the game stays open. Close the game when done.'
try {
    while (!$process.HasExited) {
        $process.Refresh()
        if ($process.HasExited) { break }
        $writer.WriteLine(('{0},{1},{2},{3},{4}' -f $clock.ElapsedMilliseconds, [DateTime]::UtcNow.ToString('o'), $process.WorkingSet64, $process.PrivateMemorySize64, $process.PeakWorkingSet64))
        $writer.Flush()
        Start-Sleep -Seconds 1
    }
} finally {
    $writer.Dispose()
}
Write-Host "Capture saved in $folder"
Write-Host 'Share game.log, frames.csv and memory.csv, plus your CPU/GPU and the level name/ID.'
