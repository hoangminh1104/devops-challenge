param([string]$ImageTag = 'v6', [switch]$Initial)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$env:AWS_PROFILE = 'AWSAdministratorAccess-730335245469'
$env:AWS_DEFAULT_PROFILE = 'AWSAdministratorAccess-730335245469'
$env:TF_DATA_DIR = "$Root/.local/730335245469/terraform-data"
function Invoke-Step([string[]]$Arguments) {
    & python "$PSScriptRoot/manage.py" @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Deployment step failed: $($Arguments[0])" }
}
Invoke-Step -Arguments @('bootstrap')
if ($Initial) {
    & terraform "-chdir=$Root/infra" apply -input=false -auto-approve -var=running=false "-var=image_tag=$ImageTag"
    if ($LASTEXITCODE -ne 0) { throw 'Infrastructure provisioning failed; inspect state before retrying' }
}
Invoke-Step -Arguments @('cloud-build', $ImageTag)
Invoke-Step -Arguments @('seed-users')
Invoke-Step -Arguments @('admin', 'migrate')
Invoke-Step -Arguments @('admin', 'seed')
Invoke-Step -Arguments @('running', $ImageTag)
Invoke-Step -Arguments @('verify')
