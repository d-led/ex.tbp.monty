<#
.SYNOPSIS
    Parses this project's PowerShell scripts with the PowerShell that runs this.

.DESCRIPTION
    Run it under both PowerShells on Windows:

        powershell -NoProfile -File scripts/check-syntax.ps1   # 5.1, what a person has
        pwsh       -NoProfile -File scripts/check-syntax.ps1   # 7

    They are not the same language. `scripts/run-desktop.ps1` parsed cleanly in
    PowerShell 7 and failed in Windows PowerShell 5.1 with "Missing closing '}'"
    about an `else` that was on a line of its own — a one-liner that then runs for
    nobody, which is the worst place to find out. Parsing takes a second; the
    packaging that would have found it takes twenty minutes.

    Exit code 0 when every file parses, 1 otherwise, naming each file that does
    not and its first errors.
#>
param(
    [string[]]$Path = @('scripts/*.ps1')
)

$failed = 0

foreach ($candidate in $Path) {
    foreach ($file in Get-ChildItem -Path $candidate -ErrorAction Stop) {
        $tokens = $null
        $problems = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$problems)

        if ($problems) {
            $failed = $failed + 1
            Write-Host "$($file.Name) does not parse in PowerShell $($PSVersionTable.PSVersion):"
            # Not `$error`: that name is a read-only automatic variable in
            # Windows PowerShell 5.1, and assigning it stops the checker instead
            # of naming the file.
            foreach ($problem in $problems) {
                Write-Host "  line $($problem.Extent.StartLineNumber): $($problem.Message)"
            }
        }
    }
}

if ($failed -gt 0) {
    exit 1
}

Write-Host "every script parses in PowerShell $($PSVersionTable.PSVersion)"
