#Requires -Modules Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement

<#
.SYNOPSIS
    Creates the lab environment for Get-MembershipGap in a test tenant.

.DESCRIPTION
    THIS SCRIPT CREATES OBJECTS IN YOUR TENANT.
    It is designed for a laboratory tenant, never for production.

    It creates four device objects with controlled names, one dynamic security
    group with a prefix-based rule, one compliance policy, one assignment, and a
    valid intent manifest.

    The cleanup inventory is written before anything is created and updated after
    each object, so that a failure part-way through still leaves a complete list
    of what exists.

    POST /devices has a narrow contract, and both halves of it are required.

    Permission: Directory.AccessAsUser.All, delegated only. It is the sole delegated
    permission for this operation, no higher-privileged one is available, and
    application permissions are not supported at all. Device.ReadWrite.All does not
    grant device creation.

    Directory role: the signed-in user must also hold a supported Entra role. The
    built-in roles documented as sufficient with least privilege for this operation
    are Intune Administrator and Windows 365 Administrator. The compliance policy
    calls later in this script are governed by Intune RBAC instead, which the API
    reference does not enumerate; Intune Administrator covers both.

    Authorization_RequestDenied on New-MgDevice means one of those two halves is
    missing. Check the session before concluding anything about the tenant:

        (Get-MgContext).Scopes -contains 'Directory.AccessAsUser.All'

    Directory.AccessAsUser.All grants the signed-in user's full directory access.
    Run this lab in a test tenant only.

.PARAMETER Prefix
    The naming prefix the dynamic rule will match. Default: 'LAB-WKS-'

.NOTES
    Requires, delegated:
      Directory.AccessAsUser.All              (device creation, no application equivalent)
      Group.ReadWrite.All
      DeviceManagementConfiguration.ReadWrite.All

    And rights on the signed-in account. The two write paths do not document the
    same thing, so they are stated separately:

      Device creation. The reference for POST /devices names Intune Administrator
      and Windows 365 Administrator as built-in roles carrying least privilege
      for the operation.

      Compliance policy creation and assignment. The reference documents the
      permission only and names no directory role. Intune RBAC governs the call,
      but the API reference does not enumerate which roles suffice.

    Intune Administrator covers both paths and is the simplest choice for a first
    run. If New-MgDevice succeeds and the policy call fails, the subject is Intune
    RBAC, not the device creation contract.

        Connect-MgGraph -Scopes Directory.AccessAsUser.All, Group.ReadWrite.All, DeviceManagementConfiguration.ReadWrite.All
#>

[CmdletBinding()]
param(
    [string]$Prefix = 'LAB-WKS-'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n  This script creates objects in your tenant." -ForegroundColor Yellow
Write-Host "  Prefix: $Prefix"
Write-Host ''

# ── Preflight ───────────────────────────────────────────────────────
# Fail on the contract, not on the first 403. A missing scope and a missing
# directory role produce the same Authorization_RequestDenied, and neither says
# anything about whether the operation is possible in this tenant.

$context = Get-MgContext
if (-not $context) {
    throw 'Not connected. Run Connect-MgGraph first.'
}

$requiredScopes = @(
    'Directory.AccessAsUser.All'
    'Group.ReadWrite.All'
    'DeviceManagementConfiguration.ReadWrite.All'
)
$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }

if ($missingScopes) {
    throw @"
Missing delegated scope(s): $($missingScopes -join ', ')

POST /devices accepts Directory.AccessAsUser.All only. There is no higher-privileged
delegated permission and no application permission for it, so Device.ReadWrite.All
and an app-only token both fail regardless of tenant configuration.

    Disconnect-MgGraph
    Connect-MgGraph -Scopes $($requiredScopes -join ', ')

The signed-in account must also hold a directory role. Intune Administrator covers both
the device creation and the compliance policy calls in this script.
"@
}

Write-Host "  Signed in as: $($context.Account)"
Write-Host '  Scopes verified. If New-MgDevice still returns Authorization_RequestDenied,'
Write-Host '  the missing half is the directory role, not the permission.'
Write-Host ''

# ── 0. Cleanup inventory, written first and updated as we go ────────

$script:cleanupPath = Join-Path $PSScriptRoot 'lab-cleanup.json'

# An existing inventory is the only record of objects a previous run may have left
# in the tenant. Writing a new one over it would lose that record, so the lab stops.
if (Test-Path -LiteralPath $script:cleanupPath) {
    throw "A cleanup inventory already exists at $script:cleanupPath. It may list objects a previous run left in the tenant. Run Remove-LabEnvironment.ps1 first; if those objects are already gone, delete the inventory by hand."
}

$script:cleanup = [PSCustomObject]@{
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    groupId   = $null
    policyId  = $null
    deviceIds = @()
}

function Save-Cleanup {
    $script:cleanup | ConvertTo-Json -Depth 5 | Set-Content -Path $script:cleanupPath -Encoding utf8
}

Save-Cleanup
Write-Host "  Cleanup inventory: $script:cleanupPath"
Write-Host ''

# ── 1. Create four device objects ───────────────────────────────────

$devices = @(
    @{ Name = "${Prefix}PC001"; Purpose = 'Matches prefix, expected in group (CorrectCoverage)' }
    @{ Name = "PC-NOPREFIX-002"; Purpose = 'No prefix, expected in group but will not match (UnderCoverage)' }
    @{ Name = "${Prefix}TEST99"; Purpose = 'Matches prefix, NOT expected in group (OverCoverage)' }
    @{ Name = "SRV-DB01"; Purpose = 'No prefix, not expected in group (CorrectExclusion)' }
)

$createdDevices = @()

foreach ($d in $devices) {
    Write-Host "  Creating device: $($d.Name)"
    Write-Host "    $($d.Purpose)"

    # Hashtable body, the form used by the official reference. Passing
    # -AlternativeSecurityIds as a named parameter forces a type conversion the
    # SDK rejects: the key must arrive as bytes, not as a base64 string.
    $params = @{
        accountEnabled         = $true
        displayName            = $d.Name
        deviceId               = (New-Guid).ToString()
        operatingSystem        = 'Windows'
        operatingSystemVersion = '11.0'
        alternativeSecurityIds = @(
            @{
                type = 2
                key  = [System.Text.Encoding]::ASCII.GetBytes($d.Name)
            }
        )
    }

    $dev = New-MgDevice -BodyParameter $params -ErrorAction Stop

    $createdDevices += [PSCustomObject]@{
        Id          = $dev.Id
        DisplayName = $d.Name
        Purpose     = $d.Purpose
    }

    $script:cleanup.deviceIds += $dev.Id
    Save-Cleanup
}

# ── 2. Create the dynamic group ─────────────────────────────────────

$groupName = 'Lab-Scope-Devices'
$rule = "(device.displayName -startsWith `"$Prefix`")"

Write-Host "`n  Creating dynamic group: $groupName"
Write-Host "  Rule: $rule"

$group = New-MgGroup -DisplayName $groupName `
    -MailEnabled:$false `
    -MailNickname 'lab-scope-devices' `
    -SecurityEnabled `
    -GroupTypes @('DynamicMembership') `
    -MembershipRule $rule `
    -MembershipRuleProcessingState 'On' `
    -ErrorAction Stop

Write-Host "  Group ID: $($group.Id)"
$script:cleanup.groupId = $group.Id
Save-Cleanup

# ── 3. Create a compliance policy ───────────────────────────────────

$policyName = 'Lab-Baseline-Win11'

Write-Host "`n  Creating compliance policy: $policyName"

# scheduledActionsForRule is a required property when creating any individual
# per-platform compliance policy, and the policy must carry exactly one block
# action. Omitting it returns 400, after the devices and the group already exist.
$policyBody = @{
    '@odata.type'          = '#microsoft.graph.windows10CompliancePolicy'
    displayName            = $policyName
    description            = 'Lab policy for Get-MembershipGap testing. Safe to delete.'
    passwordRequired       = $false
    secureBootEnabled      = $false
    bitLockerEnabled       = $false
    scheduledActionsForRule = @(
        @{
            ruleName                      = 'PasswordRequired'
            scheduledActionConfigurations = @(
                @{
                    actionType       = 'block'
                    gracePeriodHours = 0
                }
            )
        }
    )
}

$policy = New-MgDeviceManagementDeviceCompliancePolicy -BodyParameter $policyBody -ErrorAction Stop

Write-Host "  Policy ID: $($policy.Id)"
$script:cleanup.policyId = $policy.Id
Save-Cleanup

# ── 4. Assign the policy to the group ───────────────────────────────

Write-Host "`n  Assigning policy to group..."

# Assignment goes through the assign action, not through a POST on the assignments
# collection. POST /deviceCompliancePolicies/{id}/assignments has no OData route and
# returns 400 "No method match route template".
#
# Called through Invoke-MgGraphRequest rather than the SDK cmdlet on purpose:
# Set-MgDeviceManagementDeviceCompliancePolicy lives in Microsoft.Graph.DeviceManagement.Actions,
# an extra module dependency, and it throws "Object reference not set to an instance of
# an object" while the call itself succeeds server-side. A cmdlet that performs the
# write and reports failure is worse here than a raw request.
$assignBody = @{
    assignments = @(
        @{
            target = @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId       = $group.Id
            }
        }
    )
}

Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$($policy.Id)/assign" `
    -Body $assignBody `
    -ErrorAction Stop | Out-Null

# Read back, because the write path and the read path are different endpoints and the
# analyzer depends on the read one.
$check = Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $policy.Id -All -ErrorAction Stop
$assigned = $check | Where-Object { $_.Target.AdditionalProperties.groupId -eq $group.Id }
if (-not $assigned) {
    throw "The assign action returned without error but no assignment to group $($group.Id) is readable."
}
Write-Host "  Assignment confirmed by read-back."

# ── 5. Generate the intent manifest ─────────────────────────────────

$intent = [PSCustomObject]@{
    description = 'Expected workstation population for lab compliance baseline.'
    complete    = $true
    asOf        = (Get-Date).ToUniversalTime().ToString('o')
    objects     = @(
        [PSCustomObject]@{ id = $createdDevices[0].Id; displayName = $createdDevices[0].DisplayName; expectedMember = $true }
        [PSCustomObject]@{ id = $createdDevices[1].Id; displayName = $createdDevices[1].DisplayName; expectedMember = $true }
        [PSCustomObject]@{ id = $createdDevices[2].Id; displayName = $createdDevices[2].DisplayName; expectedMember = $false }
        [PSCustomObject]@{ id = $createdDevices[3].Id; displayName = $createdDevices[3].DisplayName; expectedMember = $false }
    )
}

$intentPath = Join-Path $PSScriptRoot '..' 'samples' 'lab-intent.json'
$intent | ConvertTo-Json -Depth 5 | Set-Content -Path $intentPath -Encoding utf8

# ── Summary ─────────────────────────────────────────────────────────

Write-Host "`n  Done. Objects created:" -ForegroundColor Green
Write-Host "    Devices:  $($createdDevices.Count)"
Write-Host "    Group:    $($group.Id)"
Write-Host "    Policy:   $($policy.Id)"
Write-Host "    Manifest: $intentPath"
Write-Host "    Cleanup:  $script:cleanupPath"
Write-Host ''
Write-Host '  The dynamic group needs several minutes to evaluate.' -ForegroundColor Yellow
Write-Host '  Confirm the membership before running the analyzer:'
Write-Host ''
Write-Host "    Get-MgGroupMember -GroupId '$($group.Id)' -All"
Write-Host ''
Write-Host '  Then run:'
Write-Host ''
Write-Host '    . ./Get-MembershipGap.ps1'
Write-Host "    Get-MembershipGap -GroupId '$($group.Id)' -PolicyId '$($policy.Id)' -IntentPath '$intentPath'"
Write-Host ''
