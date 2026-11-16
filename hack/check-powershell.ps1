# CI check for the Windows build scripts (run with pwsh: pwsh hack/check-powershell.ps1).
# post-install.ps1 writes several scripts into the guest as single-quoted here-strings
# (build-lib.ps1, use-sysprep-cd.ps1, setup-complete.ps1, sysprep-stage2.ps1). A parser sees those
# only as strings, so each is extracted and checked as a script of its own.
# Fails on a parse error or on a PSScriptAnalyzer finding of severity Error.
$ErrorActionPreference = 'Stop'
$files = @(Get-ChildItem -Path windows/build/config -Filter *.ps1 | ForEach-Object FullName)
$tmp = Join-Path ([IO.Path]::GetTempPath()) "ps-check-$PID"
New-Item $tmp -ItemType Directory -Force | Out-Null
$failed = $false
$scripts = [Collections.Generic.List[object]]::new()

foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) { Write-Output "PARSE ERROR $($f):$($e.Extent.StartLineNumber): $($e.Message)"; $failed = $true }
    $scripts.Add([pscustomobject]@{ Name = (Split-Path $f -Leaf); Path = $f; Line = 0 })
    # Single-quoted here-strings that look like scripts (several lines, PowerShell syntax)
    $i = 0
    foreach ($s in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
                                  $n.StringConstantType -eq 'SingleQuotedHereString' }, $true)) {
        $i++
        $line = $s.Extent.StartLineNumber
        $p = Join-Path $tmp "$((Split-Path $f -LeafBase))-heredoc$i-line$line.ps1"
        Set-Content -Path $p -Value $s.Value -Encoding utf8
        $null = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errors)
        foreach ($e in $errors) {
            Write-Output "PARSE ERROR $($f):$($line + $e.Extent.StartLineNumber): (embedded script) $($e.Message)"; $failed = $true
        }
        $scripts.Add([pscustomobject]@{ Name = "$(Split-Path $f -Leaf) here-string at line $line"; Path = $p; Line = $line })
    }
}
Write-Output "$($scripts.Count) scripts parsed: $(($scripts | ForEach-Object Name) -join '; ')"

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module PSScriptAnalyzer -RequiredVersion 1.23.0 -Scope CurrentUser -Force
}
foreach ($s in $scripts) {
    foreach ($r in Invoke-ScriptAnalyzer -Path $s.Path -Severity Error) {
        Write-Output "PSSCRIPTANALYZER $($s.Name):$($s.Line + $r.Line): $($r.RuleName): $($r.Message)"; $failed = $true
    }
}
Remove-Item $tmp -Recurse -Force
if ($failed) { Write-Output 'PowerShell checks FAILED'; exit 1 }
Write-Output 'PowerShell checks passed'
