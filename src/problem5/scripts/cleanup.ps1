param([switch]$ResetData)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Arguments = @('compose','-p','dom7hc-practice-p5','-f',"$Root/compose.yml",'down')
if ($ResetData) { $Arguments += '--volumes' }
& docker @Arguments
if ($LASTEXITCODE -ne 0) { throw 'P5 cleanup failed' }
