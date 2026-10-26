$ErrorActionPreference = 'Stop'
& python "$PSScriptRoot/manage.py" verify
if ($LASTEXITCODE -ne 0) { throw 'HTTPS functional verification failed' }
& python "$PSScriptRoot/manage.py" admin audit
if ($LASTEXITCODE -ne 0) { throw 'Database audit failed' }
