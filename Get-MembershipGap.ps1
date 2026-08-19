#Requires -Modules Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.DeviceManagement, Microsoft.Graph.Users

<#
.SYNOPSIS
    Compares the observed membership of a dynamic group against an independent intent
    manifest, and reports the gap and the assignment path that depends on it.

.DESCRIPTION
    This tool does not administer, modify, recommend or decide anything.
    It establishes what a dynamic group captures, what it misses, and whether an
    object is a member of a group directly assigned to a policy.

    Three independent dimensions, reported separately.

    Conclusion:
      GapEstablished          At least one object is under-covered or over-covered.
      NoGapEstablished        Every object is resolved, the manifest is complete,
                              and every object is in its expected state.
      CoverageNotDemonstrable No gap is proven and the assessment could not cover
                              the whole population.

    Assessment completeness, a property of the manifest:
      Complete   Manifest declared complete and fully resolved.
      Partial    Manifest incomplete, or entries unresolved.
      Absent     No manifest provided.

    Observation freshness, a property of the membership snapshot:
      Stale           Rule processing is not enabled.
      NotDemonstrated Rule processing is enabled, but convergence was not verified.

    Freshness is never asserted as good. The tool does not retrieve the rule
    processing status, so it does not claim the snapshot has converged.

    A proven gap is not erased by an incomplete assessment. The two are reported
    side by side.

    Supports dynamic user groups and dynamic device groups. The object type is
    detected from the membership rule. For user groups, Entra ID P1 is required
    for the users in scope of the dynamic rule.

.PARAMETER GroupId
    Object ID of the dynamic group to analyze.

.PARAMETER PolicyId
    Optional. Object ID of an Intune device compliance policy.
    The report verifies direct group assignment only. It does not establish
    targeting, evaluation or enforcement. Assignment filters, exclusions,
    platform, enrolment, licence and check-in state are not evaluated.

.PARAMETER IntentPath
    Optional. Path to a JSON manifest declaring the expected population.
    The manifest must explicitly declare "complete": true or false.

.PARAMETER OutputPath
    Optional. Path to write the JSON report. The report is always returned to the pipeline.

.NOTES
    Read-only. Requires:
      Group.Read.All, Device.Read.All, User.Read.All, DeviceManagementConfiguration.Read.All.
    Connect with Connect-MgGraph -Scopes before running.
#>

$script:ToolVersion = '0.1.0'

function Get-MembershipGap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GroupId,

        [string]$PolicyId,

        [string]$IntentPath,

        [string]$OutputPath
    )

    $diagnostics = [System.Collections.ArrayList]::new()

    function Add-Diagnostic {
        param([string]$Severity, [string]$Code, [string]$Object, [string]$Message)
        switch ($Severity) {
            'Warning' { Write-Warning $Message }
            'Info'    { Write-Verbose $Message }
            default   { Write-Verbose $Message }
        }
        [void]$diagnostics.Add([PSCustomObject]@{
                severity = $Severity
                code     = $Code
                object   = $Object
                message  = $Message
            })
    }

    # ── 1. Retrieve and validate the group ──────────────────────────────

    $group = Get-MgGroup -GroupId $GroupId -Property id, displayName, membershipRule, membershipRuleProcessingState, groupTypes -ErrorAction Stop

    if ('DynamicMembership' -notin $group.GroupTypes) {
        throw "Group '$($group.DisplayName)' is not a dynamic group."
    }

    $ruleState = $group.MembershipRuleProcessingState
    if ($ruleState -ne 'On') {
        Add-Diagnostic -Severity 'Warning' -Code 'RuleNotActive' -Object $group.DisplayName `
            -Message "Membership rule processing is '$ruleState', not 'On'. Observed membership may not reflect the current rule."
    }

    # ── 2. Determine object type from the rule ──────────────────────────

    $objectType = $null
    $proximitySupported = $true

    if ($group.MembershipRule -match '(?:^|[\(\s])device\.') {
        $objectType = 'device'
    }
    elseif ($group.MembershipRule -match '(?:^|[\(\s])user\.') {
        $objectType = 'user'
    }
    elseif ($group.MembershipRule -match '(?i)Direct\s+Reports\s+for') {
        $objectType = 'user'
        $proximitySupported = $false
        Add-Diagnostic -Severity 'Info' -Code 'ProximityNotSupportedForRule' -Object $group.DisplayName `
            -Message "Rule uses the 'Direct Reports for' syntax. Membership comparison is supported; proximity detection is not."
    }
    else {
        throw "Cannot determine object type from membership rule '$($group.MembershipRule)'. Supported: device.*, user.*, 'Direct Reports for'."
    }

    # ── 3. Retrieve group members ───────────────────────────────────────

    $membersRaw = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop
    $memberIndex = @{}
    foreach ($m in $membersRaw) {
        $displayName = $null
        if ($m.AdditionalProperties -and $m.AdditionalProperties.ContainsKey('displayName')) {
            $displayName = $m.AdditionalProperties['displayName']
        }
        $memberIndex[$m.Id] = @{ Id = $m.Id; DisplayName = $displayName }
    }

    # ── 4. Retrieve all objects of that type ─────────────────────────────

    if ($objectType -eq 'device') {
        $allObjects = Get-MgDevice -All -Property id, displayName -ErrorAction Stop
    }
    else {
        $allObjects = Get-MgUser -All -Property id, displayName, userType -ErrorAction Stop
    }
    $objectIndex = @{}
    foreach ($o in $allObjects) {
        $objectIndex[$o.Id] = $o
    }

    # ── 5. Load, validate and resolve the intent manifest ───────────────

    $intentStatus       = 'Absent'
    $intentComplete     = $false
    $intentDescription  = $null
    $intentAsOf         = $null
    $intentHash         = $null
    $declaredCount      = 0
    $unresolvedCount    = 0
    $duplicateCount     = 0
    $resolvedIntent     = @{}

    if ($IntentPath) {
        if (-not (Test-Path $IntentPath)) {
            throw "Intent manifest not found: $IntentPath"
        }

        $intentHash = (Get-FileHash -Path $IntentPath -Algorithm SHA256).Hash
        $intentRaw = Get-Content $IntentPath -Raw -Encoding utf8 | ConvertFrom-Json

        # Contract validation. An evidence tool does not infer its own reference.
        if ($null -eq $intentRaw.PSObject.Properties['complete']) {
            throw "Intent manifest must explicitly declare 'complete' as true or false. Omission is not an implicit true."
        }
        if ($intentRaw.complete -isnot [bool]) {
            throw "Intent manifest field 'complete' must be a JSON boolean, not '$($intentRaw.complete)'."
        }
        if ($null -eq $intentRaw.PSObject.Properties['objects']) {
            throw "Intent manifest must contain an 'objects' array."
        }

        $intentComplete    = $intentRaw.complete
        $intentDescription = $intentRaw.description

        # ConvertFrom-Json turns an ISO 8601 string into a DateTime. ConvertTo-Json
        # writes DateTime back in round-trip ISO 8601, so the JSON artifact is not
        # affected; only the console rendering of the returned object follows the
        # machine's locale. Normalized to UTC ISO 8601 anyway, so that the value is
        # the same in both places and does not depend on how the object is displayed.
        $intentAsOf = if ($intentRaw.asOf -is [datetime]) {
            $intentRaw.asOf.ToUniversalTime().ToString('o')
        }
        else {
            $intentRaw.asOf
        }
        $intentStatus      = 'Available'
        $intentEntries     = @($intentRaw.objects)
        $declaredCount     = $intentEntries.Count

        $seenIds = @{}

        foreach ($entry in $intentEntries) {
            $label = if ($entry.displayName) { $entry.displayName } elseif ($entry.id) { $entry.id } else { '(unnamed entry)' }

            if (-not $entry.id -and -not $entry.displayName) {
                Add-Diagnostic -Severity 'Warning' -Code 'IntentEntryMalformed' -Object $label `
                    -Message "Intent entry has neither 'id' nor 'displayName'. Skipped."
                $unresolvedCount++
                continue
            }
            if ($null -eq $entry.PSObject.Properties['expectedMember'] -or $entry.expectedMember -isnot [bool]) {
                Add-Diagnostic -Severity 'Warning' -Code 'IntentEntryMalformed' -Object $label `
                    -Message "Intent entry '$label' must declare 'expectedMember' as a JSON boolean. Skipped."
                $unresolvedCount++
                continue
            }

            $resolved = $null

            if ($entry.id) {
                # An explicit ID is authoritative. No fallback to name: resolving a
                # different object with the same name would be worse than not resolving.
                if ($objectIndex.ContainsKey($entry.id)) {
                    $resolved = $objectIndex[$entry.id]
                }
                else {
                    Add-Diagnostic -Severity 'Warning' -Code 'IntentObjectNotResolved' -Object $label `
                        -Message "Intent entry '$label' declares id '$($entry.id)' which does not exist in the directory. No fallback to displayName."
                    $unresolvedCount++
                    continue
                }
            }
            else {
                $nameMatches = @($allObjects | Where-Object { $_.DisplayName -eq $entry.displayName })
                if ($nameMatches.Count -eq 1) {
                    $resolved = $nameMatches[0]
                }
                elseif ($nameMatches.Count -gt 1) {
                    Add-Diagnostic -Severity 'Warning' -Code 'IntentObjectAmbiguous' -Object $label `
                        -Message "Multiple objects match displayName '$($entry.displayName)'. Cannot resolve."
                    $unresolvedCount++
                    continue
                }
                else {
                    Add-Diagnostic -Severity 'Warning' -Code 'IntentObjectNotResolved' -Object $label `
                        -Message "Intent entry '$label' not found in the directory."
                    $unresolvedCount++
                    continue
                }
            }

            if ($seenIds.ContainsKey($resolved.Id)) {
                if ($seenIds[$resolved.Id] -ne $entry.expectedMember) {
                    # A manifest that contradicts itself about an object cannot serve as
                    # a reference for that object. Silently keeping the first value would
                    # let an invalid manifest produce a confident claim.
                    throw "Intent manifest declares contradictory expectedMember values for object '$label' ($($resolved.Id))."
                }
                # An identical duplicate is inert: it changes nothing and is not a resolution failure.
                $duplicateCount++
                Add-Diagnostic -Severity 'Info' -Code 'IntentEntryDuplicate' -Object $label `
                    -Message "Object '$label' appears more than once in the manifest with the same expectedMember value."
                continue
            }

            $seenIds[$resolved.Id] = $entry.expectedMember
            $resolvedIntent[$resolved.Id] = @{
                Object         = $resolved
                ExpectedMember = $entry.expectedMember
            }
        }
    }

    # Explicit counter, not a subtraction. A benign duplicate reduces the number of
    # unique resolved objects without being a resolution failure, and must not
    # degrade the assessment.
    $notResolvedCount = $unresolvedCount

    # ── 6. Build the evaluation matrix ──────────────────────────────────

    # Over-coverage is only demonstrable when the manifest claims to be complete
    # AND every declared entry resolved. Otherwise an extra member may simply be
    # the entry that failed to resolve.
    $overCoverageDemonstrable = ($intentStatus -eq 'Available') -and $intentComplete -and ($notResolvedCount -eq 0)

    $evaluation = [System.Collections.ArrayList]::new()
    $processedIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($id in $resolvedIntent.Keys) {
        $entry = $resolvedIntent[$id]
        $inGroup = $memberIndex.ContainsKey($id)
        $expected = $entry.ExpectedMember

        $state = if ($expected -and $inGroup) { 'CorrectCoverage' }
        elseif ($expected -and -not $inGroup) { 'UnderCoverage' }
        elseif (-not $expected -and $inGroup) { 'OverCoverage' }
        else { 'CorrectExclusion' }

        [void]$evaluation.Add([PSCustomObject]@{
                objectId       = $id
                displayName    = $entry.Object.DisplayName
                expectedMember = $expected
                observedMember = $inGroup
                state          = $state
                source         = 'intent'
            })
        [void]$processedIds.Add($id)
    }

    foreach ($id in $memberIndex.Keys) {
        if ($processedIds.Contains($id)) { continue }

        $state = if ($intentStatus -eq 'Absent') { 'Observed' }
        elseif ($overCoverageDemonstrable) { 'OverCoverage' }
        else { 'NotInManifest' }

        [void]$evaluation.Add([PSCustomObject]@{
                objectId       = $id
                displayName    = $memberIndex[$id].DisplayName
                expectedMember = $null
                observedMember = $true
                state          = $state
                source         = 'group'
            })
        [void]$processedIds.Add($id)
    }

    # ── 7. Policy assignment check ──────────────────────────────────────

    $policyInfo = $null
    if ($PolicyId) {
        try {
            $policy = Get-MgDeviceManagementDeviceCompliancePolicy -DeviceCompliancePolicyId $PolicyId -ErrorAction Stop
            $assignments = Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $PolicyId -All -ErrorAction Stop

            $directAssignment = $null
            foreach ($a in $assignments) {
                $props = $a.Target.AdditionalProperties
                if ($props.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget' -and $props.groupId -eq $GroupId) {
                    $directAssignment = $props
                    break
                }
            }

            $filterId = $null
            $filterType = $null
            if ($directAssignment) {
                $filterId = $directAssignment['deviceAndAppManagementAssignmentFilterId']
                $filterType = $directAssignment['deviceAndAppManagementAssignmentFilterType']
            }
            $filterPresent = ($filterId -and $filterType -and $filterType -ne 'none')

            $policySemantics = if ($objectType -eq 'device') {
                'The device object is a member of a group that carries a direct assignment of this policy. Whether the policy is evaluated on that device depends on enrolment, platform, assignment filters, exclusions and check-in state, none of which are evaluated here.'
            }
            else {
                'The user is a member of a group that carries a direct assignment of this policy. Intune uses a user assignment to evaluate the managed devices of that user. The user object is not itself the subject of the compliance policy. Those devices, assignment filters, exclusions and enforcement are not evaluated here.'
            }

            $policyInfo = [PSCustomObject]@{
                id                           = $PolicyId
                displayName                  = $policy.DisplayName
                directGroupAssignmentPresent = [bool]$directAssignment
                objectType                   = $objectType
                assignmentFilterId           = $filterId
                assignmentFilterType         = $filterType
                assignmentFilterEvaluated    = $false
                semantics                    = $policySemantics
            }

            if (-not $directAssignment) {
                Add-Diagnostic -Severity 'Warning' -Code 'PolicyNotAssignedToGroup' -Object $policy.DisplayName `
                    -Message "Policy '$($policy.DisplayName)' has no direct assignment to group '$($group.DisplayName)'. The assignment path being analyzed does not exist."
            }
            if ($filterPresent) {
                Add-Diagnostic -Severity 'Warning' -Code 'AssignmentFilterNotEvaluated' -Object $policy.DisplayName `
                    -Message "The assignment carries an assignment filter (type '$filterType', id '$filterId') which can include or exclude objects on top of the group. This filter is not evaluated by this tool."
            }

            foreach ($entry in $evaluation) {
                $entry | Add-Member -NotePropertyName 'memberOfDirectlyAssignedGroup' `
                    -NotePropertyValue ($entry.observedMember -and [bool]$directAssignment) -Force
            }
        }
        catch {
            Add-Diagnostic -Severity 'Warning' -Code 'PolicyRetrievalFailed' -Object $PolicyId `
                -Message "Could not retrieve policy ${PolicyId}: $_"
        }
    }

    # ── 8. Proximity detection ──────────────────────────────────────────
    #
    # Runs over every object outside the group, including objects declared in the
    # manifest. The under-covered object is precisely the one most likely to carry
    # a near-miss name, so excluding manifest objects would defeat the purpose.

    $proximity = [System.Collections.ArrayList]::new()
    $rulePattern = if ($proximitySupported) { Get-RulePrefix -Rule $group.MembershipRule } else { $null }

    if ($rulePattern -and $rulePattern.Property -eq 'displayName') {
        $stateIndex = @{}
        foreach ($e in $evaluation) { $stateIndex[$e.objectId] = $e.state }

        foreach ($o in $allObjects) {
            if ($memberIndex.ContainsKey($o.Id)) { continue }

            $hint = Get-ProximityHint -Name $o.DisplayName -Pattern $rulePattern
            if ($hint) {
                [void]$proximity.Add([PSCustomObject]@{
                        objectId       = $o.Id
                        displayName    = $o.DisplayName
                        hint           = $hint
                        inGroup        = $false
                        evaluationState = if ($stateIndex.ContainsKey($o.Id)) { $stateIndex[$o.Id] } else { $null }
                        note           = 'Triage hint only. Not an established finding.'
                    })
            }
        }
    }
    elseif ($rulePattern -and $rulePattern.Property -ne 'displayName') {
        Add-Diagnostic -Severity 'Info' -Code 'ProximityNotSupportedForProperty' -Object $rulePattern.Property `
            -Message "Proximity detection supports rules on 'displayName' only. Rule property is '$($rulePattern.Property)'."
    }

    # ── 9. Summary, conclusion and completeness ─────────────────────────

    $counts = @{
        CorrectCoverage  = @($evaluation | Where-Object state -EQ 'CorrectCoverage').Count
        UnderCoverage    = @($evaluation | Where-Object state -EQ 'UnderCoverage').Count
        OverCoverage     = @($evaluation | Where-Object state -EQ 'OverCoverage').Count
        CorrectExclusion = @($evaluation | Where-Object state -EQ 'CorrectExclusion').Count
        NotInManifest    = @($evaluation | Where-Object state -EQ 'NotInManifest').Count
        Observed         = @($evaluation | Where-Object state -EQ 'Observed').Count
        NotResolved      = $notResolvedCount
    }

    $hasGap = ($counts.UnderCoverage -gt 0) -or ($counts.OverCoverage -gt 0)

    # Axis 1: completeness of the intent. A property of the manifest.
    $incompletenessReasons = @()
    if ($intentStatus -eq 'Absent') { $incompletenessReasons += 'No intent manifest was provided.' }
    if ($intentStatus -eq 'Available' -and -not $intentComplete) { $incompletenessReasons += 'The manifest declares itself as not complete.' }
    if ($notResolvedCount -gt 0) { $incompletenessReasons += "$notResolvedCount manifest entries could not be resolved in the directory." }

    $assessmentCompleteness = if ($intentStatus -eq 'Absent') { 'Absent' }
    elseif ($incompletenessReasons.Count -gt 0) { 'Partial' }
    else { 'Complete' }

    # Axis 2: freshness of the observation. A property of the membership snapshot.
    #
    # membershipRuleProcessingState only states whether processing is enabled. It does
    # not state whether the current population has converged. Entra tracks that
    # separately (Evaluating, Processing, Update complete, Processing error, Not started),
    # and that status is not retrieved by this version. So freshness is never asserted:
    # it is either demonstrably stale, or not demonstrated.
    $freshness = if ($ruleState -ne 'On') { 'Stale' } else { 'NotDemonstrated' }

    $observation = [PSCustomObject]@{
        processingState  = $ruleState
        processingStatus = 'NotRetrieved'
        freshness        = $freshness
        note             = if ($freshness -eq 'Stale') {
            "Membership rule processing state is '$ruleState'. The retrieved membership may predate the current rule."
        }
        else {
            'Rule processing is enabled. Whether the current membership has finished converging was not established: the processing status was not retrieved.'
        }
    }

    $conclusion = if ($hasGap) {
        $parts = @()
        if ($counts.UnderCoverage -gt 0) { $parts += "$($counts.UnderCoverage) expected in group but absent" }
        if ($counts.OverCoverage -gt 0) { $parts += "$($counts.OverCoverage) in group but not expected" }

        [PSCustomObject]@{
            result               = 'GapEstablished'
            detail               = ($parts -join '. ') + '.'
            gapBreakCondition    = 'The manifest is outdated or wrong about the expected state of these objects, or the observed membership was not current at generation time.'
            policyImpactBoundary = 'Other assignment paths, exclusions, assignment filters and enforcement conditions were not evaluated. A gap in this group does not establish that the object receives nothing.'
        }
    }
    elseif ($assessmentCompleteness -ne 'Complete' -or $freshness -eq 'Stale') {
        $reasons = @($incompletenessReasons)
        if ($freshness -eq 'Stale') { $reasons += $observation.note }

        [PSCustomObject]@{
            result               = 'CoverageNotDemonstrable'
            detail               = 'No gap was proven, and the assessment could not cover the whole population. ' + ($reasons -join ' ')
            gapBreakCondition    = $null
            policyImpactBoundary = $null
        }
    }
    else {
        [PSCustomObject]@{
            result               = 'NoGapEstablished'
            detail               = 'No gap was observed in the retrieved membership snapshot. The manifest was complete and fully resolved. Membership processing freshness was not independently established.'
            gapBreakCondition    = 'The manifest is outdated, or it declares itself complete while omitting part of the real population, or the membership had not finished converging when it was read.'
            policyImpactBoundary = $null
        }
    }

    # ── 10. Build and return the report ─────────────────────────────────

    $report = [PSCustomObject]@{
        metadata     = [PSCustomObject]@{
            toolVersion       = $script:ToolVersion
            generatedAt       = (Get-Date).ToUniversalTime().ToString('o')
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            disclaimer        = 'Conclusions are bounded to the analyzed path. Other assignment mechanisms were not evaluated.'
        }
        group        = [PSCustomObject]@{
            id                            = $group.Id
            displayName                   = $group.DisplayName
            membershipRule                = $group.MembershipRule
            membershipRuleProcessingState = $ruleState
            memberCount                   = $memberIndex.Count
            objectType                    = $objectType
        }
        intentSource = [PSCustomObject]@{
            status              = $intentStatus
            path                = $IntentPath
            description         = $intentDescription
            asOf                = $intentAsOf
            sha256              = $intentHash
            complete            = if ($intentStatus -eq 'Available') { $intentComplete } else { $null }
            declaredObjectCount = $declaredCount
            resolvedObjectCount = $resolvedIntent.Count
            notResolved         = $notResolvedCount
            duplicatesIgnored   = $duplicateCount
        }
        policy       = $policyInfo
        evaluation   = $evaluation.ToArray()
        proximity    = $proximity.ToArray()
        summary      = [PSCustomObject]$counts
        assessment   = [PSCustomObject]@{
            completeness = $assessmentCompleteness
            reasons      = $incompletenessReasons
        }
        observation  = $observation
        conclusion   = $conclusion
        diagnostics  = $diagnostics.ToArray()
    }

    # ── Terminal summary ────────────────────────────────────────────────

    Write-Host ''
    Write-Host "  Group:  $($group.DisplayName) ($($memberIndex.Count) members, $objectType)"
    Write-Host "  Rule:   $($group.MembershipRule)"
    if ($intentStatus -eq 'Available') {
        # Every gap between declared and resolved is named on the terminal, so the
        # reader never has to open the JSON to find out where an entry went.
        $intentNotes = @()
        if ($duplicateCount -gt 0) { $intentNotes += "$duplicateCount duplicate ignored" }
        if ($notResolvedCount -gt 0) { $intentNotes += "$notResolvedCount unresolved" }
        $suffix = if ($intentNotes.Count -gt 0) { ' (' + ($intentNotes -join ', ') + ')' } else { '' }

        Write-Host "  Intent: $declaredCount declared, $($resolvedIntent.Count) unique resolved$suffix, complete=$intentComplete"
    }
    else {
        Write-Host "  Intent: Absent"
    }
    if ($policyInfo) {
        Write-Host "  Policy: $($policyInfo.displayName) (direct group assignment: $($policyInfo.directGroupAssignmentPresent))"
    }
    Write-Host ''
    if ($intentStatus -ne 'Absent') {
        Write-Host "  Correct coverage:  $($counts.CorrectCoverage)"
        Write-Host "  Under-coverage:    $($counts.UnderCoverage)"
        Write-Host "  Over-coverage:     $($counts.OverCoverage)"
        Write-Host "  Correct exclusion: $($counts.CorrectExclusion)"
        if ($counts.NotInManifest -gt 0) { Write-Host "  Not in manifest:   $($counts.NotInManifest)" }
        if ($counts.NotResolved -gt 0) { Write-Host "  Not resolved:      $($counts.NotResolved)" }
        Write-Host ''
    }
    Write-Host "  Conclusion:   $($conclusion.result)" -ForegroundColor $(
        switch ($conclusion.result) {
            'GapEstablished' { 'Yellow' }
            'NoGapEstablished' { 'Green' }
            'CoverageNotDemonstrable' { 'DarkYellow' }
        }
    )
    Write-Host "  Assessment:   $assessmentCompleteness" -ForegroundColor $(
        switch ($assessmentCompleteness) {
            'Complete' { 'Green' }
            default { 'DarkYellow' }
        }
    )
    Write-Host "  Freshness:    $freshness" -ForegroundColor $(
        if ($freshness -eq 'Stale') { 'Yellow' } else { 'DarkGray' }
    )
    if ($diagnostics.Count -gt 0) {
        Write-Host "  Diagnostics:  $($diagnostics.Count)" -ForegroundColor DarkYellow
    }
    Write-Host ''

    if ($OutputPath) {
        $report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding utf8
        Write-Host "  Report written to $OutputPath"
        Write-Host ''
    }

    return $report
}


# ═══════════════════════════════════════════════════════════════════════
#  Internal helpers
# ═══════════════════════════════════════════════════════════════════════

function Get-RulePrefix {
    <#
    .SYNOPSIS
        Extracts property, operator and value from a simple single-expression
        dynamic membership rule. Returns $null for compound or unsupported rules.

        Only -startsWith and -eq are supported. -contains is deliberately excluded:
        no defensible proximity signal exists for it, and claiming support without
        producing a hint would be a false promise.
    #>
    param([string]$Rule)

    if ($Rule -match '^\s*\(?\s*(?:device|user)\.(\w+)\s+-(startsWith|eq)\s+"([^"]+)"\s*\)?\s*$') {
        return [PSCustomObject]@{
            Property = $Matches[1]
            Operator = $Matches[2]
            Value    = $Matches[3]
        }
    }
    return $null
}


function Get-ProximityHint {
    <#
    .SYNOPSIS
        Returns a hint string if the object name is close to the rule pattern.
        Returns $null if no proximity is detected.

        Entra dynamic membership string operations are case-insensitive, so a case
        difference does not produce a membership gap and is not flagged.
    #>
    param(
        [string]$Name,
        [PSCustomObject]$Pattern
    )

    if (-not $Name -or -not $Pattern) { return $null }

    $value = $Pattern.Value

    switch ($Pattern.Operator) {
        'startsWith' {
            if ($Name -like "$value*") { return $null }

            # Normalize the whole name, not a window the width of the raw prefix.
            # An omitted separator makes the name shorter than that window, so a
            # windowed comparison silently misses the most interesting case.
            $normalizedName  = ($Name  -replace '[-_.\s]', '').ToLowerInvariant()
            $normalizedValue = ($value -replace '[-_.\s]', '').ToLowerInvariant()

            if ($normalizedName.StartsWith($normalizedValue)) {
                return "Separator difference: '$Name' vs expected prefix '$value'"
            }

            if ($Name.ToLowerInvariant().Contains($value.ToLowerInvariant())) {
                return "Contains '$value' but not at start"
            }
        }
        'eq' {
            if ($Name -eq $value) { return $null }

            $normalizeA = $Name -replace '[-_.\s]', ''
            $normalizeB = $value -replace '[-_.\s]', ''
            if ($normalizeA.ToLowerInvariant() -eq $normalizeB.ToLowerInvariant()) {
                return "Separator difference: '$Name' vs '$value'"
            }
        }
    }

    return $null
}
