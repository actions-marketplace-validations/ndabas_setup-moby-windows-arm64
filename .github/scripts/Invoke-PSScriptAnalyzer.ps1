<#
.SYNOPSIS
    Runs PSScriptAnalyzer on the repository's PowerShell scripts and on the
    pwsh steps embedded in action.yml and the workflows.

.DESCRIPTION
    Requires the PSScriptAnalyzer module and yq (https://github.com/mikefarah/yq).
    Findings are written as GitHub Actions annotations when run in Actions.
    Exits with 1 if there are any findings.
#>
[CmdletBinding()]
param(
    [string] $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'
$settings = Join-Path $Root 'PSScriptAnalyzerSettings.psd1'
$findings = [System.Collections.Generic.List[object]]::new()

function Add-Finding($Record, [string] $File, [int] $Line) {
    $findings.Add([pscustomobject]@{
        File     = ([IO.Path]::GetRelativePath($Root, $File) -replace '\\', '/')
        Line     = $Line
        Severity = $Record.Severity
        Rule     = $Record.RuleName
        Message  = $Record.Message
    })
}

foreach ($file in Get-ChildItem $Root -Recurse -Include *.ps1, *.psm1, *.psd1 -File) {
    foreach ($r in Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings) {
        Add-Finding $r $file.FullName $r.Line
    }
}

$yamlFiles = @(Get-Item (Join-Path $Root 'action.yml')) +
    @(Get-ChildItem (Join-Path $Root '.github/workflows') -Include *.yml, *.yaml -Recurse -File)
foreach ($file in $yamlFiles) {
    # "line" is the line of the "run: |" key, so script line N is file line (line + N).
    $json = yq -o=json '[.. | select(tag == "!!map" and .shell == "pwsh" and has("run")) | {"line": (.run | line), "run": .run}]' $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "yq failed on $file" }
    foreach ($step in ($json | ConvertFrom-Json)) {
        # Actions substitutes ${{ }} expressions before PowerShell sees the script.
        $script = $step.run -replace '\$\{\{.*?\}\}', 'EXPR'
        foreach ($r in Invoke-ScriptAnalyzer -ScriptDefinition $script -Settings $settings) {
            Add-Finding $r $file.FullName ($step.line + $r.Line)
        }
    }
}

foreach ($f in $findings) {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $level = if ($f.Severity -eq 'Error') { 'error' } else { 'warning' }
        Write-Host "::$level file=$($f.File),line=$($f.Line),title=$($f.Rule)::$($f.Message)"
    } else {
        Write-Host "$($f.File):$($f.Line): $($f.Severity) $($f.Rule): $($f.Message)"
    }
}

if ($findings.Count) {
    Write-Host "PSScriptAnalyzer found $($findings.Count) issue(s)."
    exit 1
}
Write-Host 'PSScriptAnalyzer found no issues.'
