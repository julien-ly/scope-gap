# Parse-level checks over every script in the repository.
#
# Get-MembershipGap.Tests.ps1 dot-sources the analyzer, so a syntax error there
# fails loudly. The lab scripts are never loaded by any test, so a broken quote
# in one of them survived a full green run and only surfaced when the script was
# executed against a tenant. These tests close that gap. They assert nothing
# about behaviour, only that every script parses and that the shipped samples
# agree with each other.
#
# Written without -ForEach and without BeforeDiscovery on purpose: a discovery
# time failure would take down the whole run, including the analyzer tests.

Describe 'Repository integrity' {

    BeforeAll {
        $script:root = Split-Path $PSScriptRoot -Parent
    }

    It 'every PowerShell file parses' {
        $failures = @()

        # foreach statement, not ForEach-Object: the pipeline cmdlet runs its block in
        # a child scope, so $failures += inside it would write to a local copy and the
        # test would pass no matter what.
        foreach ($file in Get-ChildItem -Path $script:root -Filter *.ps1 -Recurse -File) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

            if ($errors -and $errors.Count -gt 0) {
                $relative = $file.FullName.Substring($script:root.Length).TrimStart('\', '/')
                foreach ($e in $errors) {
                    $failures += "$relative line $($e.Extent.StartLineNumber): $($e.Message)"
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ("Parse errors found:" + [Environment]::NewLine + ($failures -join [Environment]::NewLine))
        }

        $failures.Count | Should -Be 0
    }

    It 'ships the manifest that the recorded report was produced from' {
        Test-Path (Join-Path $script:root 'samples/lab-intent.json') | Should -BeTrue
        Test-Path (Join-Path $script:root 'samples/output.json') | Should -BeTrue
    }

    It 'the recorded report sha256 matches the shipped manifest byte for byte' {
        $report = Get-Content (Join-Path $script:root 'samples/output.json') -Raw | ConvertFrom-Json
        $actual = (Get-FileHash -Path (Join-Path $script:root 'samples/lab-intent.json') -Algorithm SHA256).Hash
        $actual | Should -Be $report.intentSource.sha256
    }

    It 'every shipped manifest declares complete explicitly' {
        $offenders = @()

        foreach ($file in Get-ChildItem -Path (Join-Path $script:root 'samples') -Filter *.json -File) {
            $json = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($json.PSObject.Properties['objects']) {
                if (-not $json.PSObject.Properties['complete']) {
                    $offenders += $file.Name
                }
            }
        }

        $offenders -join ', ' | Should -BeNullOrEmpty
    }
}
