$ErrorActionPreference = "Stop"
Set-Location -LiteralPath 'C:\candidate-7c36229823-rehearsal4'
try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $harnessArgs = @(Get-Content -LiteralPath 'C:\Users\Public\external-cert-rehearsal-7c36229823-runner-v11\ui-automation\harness-args.json' -Raw | ConvertFrom-Json)
    $dotnetOutput = & dotnet @harnessArgs 2>&1
    $code = $LASTEXITCODE
    $dotnetOutput | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        } else {
            $_.ToString()
        }
    } | Set-Content -LiteralPath 'C:\Users\Public\external-cert-rehearsal-7c36229823-runner-v11\ui-automation\harness-console.log' -Encoding UTF8
    $ErrorActionPreference = $previousErrorActionPreference
} catch {
    $ErrorActionPreference = "Continue"
    $code = 1
    $_.Exception.ToString() | Tee-Object -FilePath 'C:\Users\Public\external-cert-rehearsal-7c36229823-runner-v11\ui-automation\harness-console.log' -Append
}
Set-Content -LiteralPath 'C:\Users\Public\external-cert-rehearsal-7c36229823-runner-v11\ui-automation\exit-code.txt' -Value $code -Encoding ASCII
exit $code
