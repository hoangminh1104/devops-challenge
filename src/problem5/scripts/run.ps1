param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Project = 'dom7hc-practice-p5'
& node "$PSScriptRoot/setup.mjs"
if ($LASTEXITCODE -ne 0) { throw 'P5 setup failed' }
$Up = @('compose','-p',$Project,'-f',"$Root/compose.yml",'up','-d','--wait')
if ($SkipBuild) { $Up += @('--no-build','--pull','never') } else { $Up += '--build' }
$Up += @('db','api-a','api-b','worker')
& docker @Up
if ($LASTEXITCODE -ne 0) { throw 'P5 startup failed; inspect only this Compose project' }
& node "$PSScriptRoot/inspect.mjs"
if ($LASTEXITCODE -ne 0) { throw 'P5 runtime isolation checks failed' }
& docker compose -p $Project -f "$Root/compose.yml" --profile verify run --rm --no-deps --pull never tests
if ($LASTEXITCODE -ne 0) { throw 'P5 security integration tests failed; inspect evidence and project logs' }
'P5 checks passed. Evidence: src/problem5/evidence/. Use scripts/cleanup.ps1 when finished.'
