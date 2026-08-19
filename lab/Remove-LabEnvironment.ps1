#Requires -Modules Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement

<#
.SYNOPSIS
    Removes the objects created by New-LabEnvironment.ps1.

.DESCRIPTION
    Reads lab-cleanup.json and deletes the policy, group and device objects.

    The inventory file is deleted only when every object has been removed or
    confirmed already absent. If any deletion fails for another reason, the
    inventory is kept: it is the only record of what still exists.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$cleanupPath = Join-Path $PSScriptRoot 'lab-cleanup.json'
if (-not (Test-Path $cleanupPath)) {
    Write-Warning "No inventory found at $cleanupPath. Nothing to remove."
    return
}

$cleanup = Get-Content $cleanupPath -Raw -Encoding utf8 | ConvertFrom-Json

Write-Host "`n  Removing lab objects..." -ForegroundColor Yellow

$remaining = [System.Collections.ArrayList]::new()

function Remove-LabObject {
    param(
        [string]$Kind,
        [string]$Id,
        [scriptblock]$Action
    )

    if (-not $Id) { return }

    try {
        & $Action
        Write-Host "    $Kind $Id removed."
    }
    catch {
        $notFound = $_.Exception.Message -match 'not found|does not exist|Resource.*not found|Request_ResourceNotFound'
        if ($notFound) {
            Write-Host "    $Kind $Id already absent."
        }
        else {
            Write-Warning "    $Kind ${Id}: $($_.Exception.Message)"
            [void]$remaining.Add("$Kind $Id")
        }
    }
}

Remove-LabObject -Kind 'Policy' -Id $cleanup.policyId -Action {
    Remove-MgDeviceManagementDeviceCompliancePolicy -DeviceCompliancePolicyId $cleanup.policyId -ErrorAction Stop
}

Remove-LabObject -Kind 'Group' -Id $cleanup.groupId -Action {
    Remove-MgGroup -GroupId $cleanup.groupId -ErrorAction Stop
}

foreach ($id in $cleanup.deviceIds) {
    Remove-LabObject -Kind 'Device' -Id $id -Action {
        Remove-MgDevice -DeviceId $id -ErrorAction Stop
    }
}

if ($remaining.Count -eq 0) {
    Remove-Item $cleanupPath -Force
    Write-Host "`n  Cleanup complete. Inventory removed.`n" -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Warning "$($remaining.Count) object(s) could not be removed. The inventory is kept at $cleanupPath so they can be found again:"
    foreach ($r in $remaining) { Write-Host "    $r" }
    Write-Host ''
}
