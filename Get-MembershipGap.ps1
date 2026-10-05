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
      CoverageNotDemonstrable No gap is proven, and coverage cannot be demonstrated:
                              the assessment could not cover the whole population,
                              or the membership predates the current rule.

    Assessment completeness, a property of the manifest:
      Complete   Manifest declared complete and fully resolved.
      Partial    Manifest incomplete, or entries unresolved.
      Absent     No manifest provided.

    Observation freshness, a property of the membership snapshot:
      Stale           Rule processing is not enabled, or the current rule failed
                      to evaluate. Either way the membership predates the rule.
      NotDemonstrated Rule processing is enabled and did not fail, but convergence
                      of the snapshot was not verified.

    Freshness is never asserted as good, not even when the last processing run
    succeeded. The processing status is read from the Microsoft Graph beta
    endpoint. A failed read is reported and never interpreted.

    A group whose rule failed to evaluate keeps the membership of its last
    successful evaluation and stops following the rule. A gap observed on such a
    group is still a gap. An absence of gap on such a group is not demonstrated
    coverage, and is reported as CoverageNotDemonstrable.

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
    The processing status is read from the beta endpoint with Group.Read.All.
    Connect with Connect-MgGraph -Scopes before running.

    Either dot-source this file and call Get-MembershipGap, or run the file with
    the same parameters.
#>

$script:ToolVersion   = '0.2.0'
$script:SchemaVersion = '2'

function Get-MembershipGap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GroupId,

        [string]$PolicyId,

        [string]$IntentPath,

        [string]$OutputPath
    )

    # The analyzer is tested without strict mode, and its result must not depend on
    # the mode of whoever calls it. Strict mode inherited from a caller used to make
    # a valid manifest fail on an entry that carries an id and no displayName.
    Set-StrictMode -Off

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

    $group = Get-MgGroup -GroupId $GroupId -Property id, displayName, membershipRule, membershipRuleProcessingState, groupTypes, createdDateTime -ErrorAction Stop

    if ('DynamicMembership' -notin $group.GroupTypes) {
        throw "Group '$($group.DisplayName)' is not a dynamic group."
    }

    $ruleState = $group.MembershipRuleProcessingState
    if ($ruleState -ne 'On') {
        Add-Diagnostic -Severity 'Warning' -Code 'RuleNotActive' -Object $group.DisplayName `
            -Message "Membership rule processing is '$ruleState', not 'On'. Observed membership may not reflect the current rule."
    }

    # ── 1b. Retrieve the rule processing status (beta) ──────────────────
    #
    # membershipRuleProcessingState only states whether processing is enabled.
    # Whether the current rule was evaluated, and whether that evaluation failed,
    # is in membershipRuleProcessingStatus, documented on the beta endpoint and
    # returned only on an explicit $select. A failed read is reported and never
    # interpreted: the report then reads as if the status had not been requested.

    $processingStatus  = 'NotRetrieved'
    $processingError   = $null
    $lastMembershipRaw = $null
    $statusRetrieved   = $false

    try {
        $statusResponse = Invoke-MgGraphRequest -Method GET -OutputType HashTable -ErrorAction Stop `
            -Uri ("https://graph.microsoft.com/beta/groups/$GroupId" + '?$select=id,membershipRuleProcessingStatus')
        $statusRetrieved = $true
        $statusObject = Get-OptionalProperty -Object $statusResponse -Name 'membershipRuleProcessingStatus'
        $statusValue  = Get-OptionalProperty -Object $statusObject -Name 'status'
        $processingStatus  = if ([string]::IsNullOrEmpty([string]$statusValue)) { 'NotReported' } else { [string]$statusValue }
        $processingError   = Get-OptionalProperty -Object $statusObject -Name 'errorMessage'
        $lastMembershipRaw = Get-OptionalProperty -Object $statusObject -Name 'lastMembershipUpdated'
    }
    catch {
        $readFailure = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $readFailure += ' ' + $_.ErrorDetails.Message }
        Add-Diagnostic -Severity 'Warning' -Code 'ProcessingStatusNotRetrieved' -Object $group.DisplayName `
            -Message "The rule processing status could not be read from the beta endpoint, so freshness is reported without it. $readFailure"
    }

    $processingFailed = ($processingStatus -eq 'Failed')
    if ($processingFailed) {
        $failureText = if ($processingError) { "'$processingError'" } else { 'no error message was reported' }
        Add-Diagnostic -Severity 'Warning' -Code 'RuleProcessingFailed' -Object $group.DisplayName `
            -Message "Rule processing failed: $failureText. The group keeps the membership of its last successful evaluation and no longer follows its rule."
    }

    # A last membership change earlier than the group itself is impossible, so it is a
    # placeholder and not a date. The test is deliberately not a list of the placeholder
    # values seen so far: they are undocumented. One hour of tolerance absorbs clock
    # differences between services; the placeholders seen so far are decades off.
    $lastMembershipText   = $null
    $lastMembershipDate   = $null
    $lastMembershipUsable = $null
    if ($lastMembershipRaw -is [datetime]) {
        $lastMembershipDate = $lastMembershipRaw.ToUniversalTime()
        $lastMembershipText = $lastMembershipDate.ToString('o')
    }
    elseif (-not [string]::IsNullOrEmpty([string]$lastMembershipRaw)) {
        $lastMembershipText = [string]$lastMembershipRaw
        $parsedDate = [datetime]::MinValue
        $dateStyles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if ([datetime]::TryParse($lastMembershipText, [System.Globalization.CultureInfo]::InvariantCulture, $dateStyles, [ref]$parsedDate)) {
            $lastMembershipDate = $parsedDate
        }
    }
    $groupCreated     = $null
    $groupCreatedText = $null
    if ($group.CreatedDateTime) {
        $groupCreated     = ([datetime]$group.CreatedDateTime).ToUniversalTime()
        $groupCreatedText = $groupCreated.ToString('o')
    }
    if ($null -ne $lastMembershipDate -and $null -ne $groupCreated) {
        $lastMembershipUsable = ($lastMembershipDate -ge $groupCreated.AddHours(-1))
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
        $intentDescription = Get-OptionalProperty -Object $intentRaw -Name 'description'
        $intentAsOfRaw     = Get-OptionalProperty -Object $intentRaw -Name 'asOf'

        # ConvertFrom-Json turns an ISO 8601 string into a DateTime. ConvertTo-Json
        # writes DateTime back in round-trip ISO 8601, so the JSON artifact is not
        # affected; only the console rendering of the returned object follows the
        # machine's locale. Normalized to UTC ISO 8601 anyway, so that the value is
        # the same in both places and does not depend on how the object is displayed.
        $intentAsOf = if ($intentAsOfRaw -is [datetime]) {
            $intentAsOfRaw.ToUniversalTime().ToString('o')
        }
        else {
            $intentAsOfRaw
        }
        $intentStatus      = 'Available'
        $intentEntries     = @($intentRaw.objects)
        $declaredCount     = $intentEntries.Count

        $seenIds = @{}

        foreach ($entry in $intentEntries) {
            # Both fields are optional in the contract, so they are read without
            # assuming that they exist.
            $entryId   = Get-OptionalProperty -Object $entry -Name 'id'
            $entryName = Get-OptionalProperty -Object $entry -Name 'displayName'
            $label = if ($entryName) { $entryName } elseif ($entryId) { $entryId } else { '(unnamed entry)' }

            if (-not $entryId -and -not $entryName) {
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

            if ($entryId) {
                # An explicit ID is authoritative. No fallback to name: resolving a
                # different object with the same name would be worse than not resolving.
                if ($objectIndex.ContainsKey($entryId)) {
                    $resolved = $objectIndex[$entryId]
                }
                else {
                    Add-Diagnostic -Severity 'Warning' -Code 'IntentObjectNotResolved' -Object $label `
                        -Message "Intent entry '$label' declares id '$entryId' which does not exist in the directory. No fallback to displayName."
                    $unresolvedCount++
                    continue
                }
            }
            else {
                $nameMatches = @($allObjects | Where-Object { $_.DisplayName -eq $entryName })
                if ($nameMatches.Count -eq 1) {
                    $resolved = $nameMatches[0]
                }
                elseif ($nameMatches.Count -gt 1) {
                    Add-Diagnostic -Severity 'Warning' -Code 'IntentObjectAmbiguous' -Object $label `
                        -Message "Multiple objects match displayName '$entryName'. Cannot resolve."
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
    # membershipRuleProcessingState only states whether processing is enabled. The
    # processing status states whether the current rule was evaluated. Freshness is
    # never asserted as good, not even after a successful run: it is demonstrably
    # stale, or not demonstrated.
    #
    # A failed evaluation makes the snapshot stale for the same reason a paused rule
    # does: the retrieved membership predates the current rule. The group keeps the
    # population of its last successful evaluation, so an absence of gap there is
    # coverage by inertia, not demonstrated coverage.
    $freshness = if ($ruleState -ne 'On' -or $processingFailed) { 'Stale' } else { 'NotDemonstrated' }

    $lastMembershipNote = if ($null -eq $lastMembershipText) { 'not reported' }
    elseif ($lastMembershipUsable -eq $true) { $lastMembershipText }
    elseif ($lastMembershipUsable -eq $false) { "$lastMembershipText, earlier than the group itself, so a placeholder and not a date" }
    else { "$lastMembershipText, usability not established" }

    $failureSuffix = if ($processingError) { ": '$processingError'" } else { '' }

    $observationNote = if ($processingFailed) {
        "Rule processing failed$failureSuffix. The retrieved membership comes from an earlier successful evaluation and is no longer maintained: objects that now match the intent are not added. Waiting will not change it until the rule is corrected."
    }
    elseif ($ruleState -ne 'On') {
        "Membership rule processing state is '$ruleState'. The retrieved membership may predate the current rule."
    }
    elseif ($processingStatus -eq 'NotRetrieved') {
        'Rule processing is enabled. Whether the current membership has finished converging was not established: the processing status could not be read.'
    }
    elseif ($processingStatus -eq 'NotReported') {
        'Rule processing is enabled. The service reported no processing status, so whether the current membership has finished converging was not established.'
    }
    elseif ($processingStatus -eq 'Succeeded') {
        "Rule processing is enabled and its last run succeeded (last membership change: $lastMembershipNote). Convergence of this snapshot was not independently established."
    }
    else {
        "Rule processing is '$processingStatus'. The retrieved membership may not reflect the current rule yet."
    }

    $observation = [PSCustomObject]@{
        processingState       = $ruleState
        processingStatus      = $processingStatus
        processingError       = $processingError
        lastMembershipUpdated = $lastMembershipText
        lastMembershipUsable  = $lastMembershipUsable
        freshness             = $freshness
        note                  = $observationNote
    }

    $conclusion = if ($hasGap) {
        $parts = @()
        if ($counts.UnderCoverage -gt 0) { $parts += "$($counts.UnderCoverage) expected in group but absent" }
        if ($counts.OverCoverage -gt 0) { $parts += "$($counts.OverCoverage) in group but not expected" }

        # When the rule failed to evaluate, the delay reading of the break condition
        # is wrong: the gap does not close by waiting.
        $gapBreakCondition = if ($processingFailed) {
            'The membership is not maintained: rule processing failed and the group keeps the population of its last successful evaluation. The gap will not close by waiting; the rule must be corrected. Independently, the manifest may be outdated or wrong about the expected state of these objects.'
        }
        else {
            'The manifest is outdated or wrong about the expected state of these objects, or the observed membership was not current at generation time.'
        }

        [PSCustomObject]@{
            result               = 'GapEstablished'
            detail               = ($parts -join '. ') + '.'
            gapBreakCondition    = $gapBreakCondition
            policyImpactBoundary = 'Other assignment paths, exclusions, assignment filters and enforcement conditions were not evaluated. A gap in this group does not establish that the object receives nothing.'
        }
    }
    elseif ($assessmentCompleteness -ne 'Complete' -or $freshness -eq 'Stale') {
        $reasons = @($incompletenessReasons)
        if ($freshness -eq 'Stale') { $reasons += $observation.note }

        [PSCustomObject]@{
            result               = 'CoverageNotDemonstrable'
            detail               = 'No gap was proven, and coverage could not be demonstrated. ' + ($reasons -join ' ')
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

    # Rows and manifest entries are different units. An entry that fails to resolve
    # produces no row, so the two families are kept apart and never summed.
    $summary = [PSCustomObject]@{
        rowUnit         = 'object'
        rows            = [PSCustomObject]@{
            CorrectCoverage  = $counts.CorrectCoverage
            UnderCoverage    = $counts.UnderCoverage
            OverCoverage     = $counts.OverCoverage
            CorrectExclusion = $counts.CorrectExclusion
            NotInManifest    = $counts.NotInManifest
            Observed         = $counts.Observed
        }
        manifestEntries = [PSCustomObject]@{
            NotResolved = $counts.NotResolved
        }
    }

    $context = Get-MgContext
    $graphModules = @(Get-Module -Name 'Microsoft.Graph.*' | Sort-Object Name, Version | ForEach-Object {
            [PSCustomObject]@{ name = $_.Name; version = $_.Version.ToString() }
        })

    $report = [PSCustomObject]@{
        metadata     = [PSCustomObject]@{
            schemaVersion     = $script:SchemaVersion
            toolVersion       = $script:ToolVersion
            generatedAt       = (Get-Date).ToUniversalTime().ToString('o')
            tenantId          = if ($context) { $context.TenantId } else { $null }
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            graphModules      = $graphModules
            disclaimer        = 'Conclusions are bounded to the analyzed path. Other assignment mechanisms were not evaluated.'
        }
        sources      = @(
            [PSCustomObject]@{
                product    = 'Microsoft Graph'
                apiVersion = 'v1.0'
                stability  = 'generally available'
                reads      = 'group, members, directory objects, policy assignment'
                retrieved  = $true
            }
            [PSCustomObject]@{
                product    = 'Microsoft Graph'
                apiVersion = 'beta'
                stability  = 'preview'
                reads      = 'membershipRuleProcessingStatus'
                retrieved  = $statusRetrieved
            }
        )
        group        = [PSCustomObject]@{
            id                            = $group.Id
            displayName                   = $group.DisplayName
            createdDateTime               = $groupCreatedText
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
        summary      = $summary
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
    Write-Host "  Processing:   $processingStatus" -ForegroundColor $(
        if ($processingFailed) { 'Yellow' } else { 'DarkGray' }
    )
    if ($processingFailed -and $processingError) {
        Write-Host "                $processingError" -ForegroundColor DarkYellow
    }
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

function Get-OptionalProperty {
    <#
    .SYNOPSIS
        Reads a property that may be absent, from a dictionary or an object.

    .DESCRIPTION
        Manifest entries carry optional fields, and Graph responses read as
        hashtables may omit keys. A direct property access on an absent field
        throws under strict mode. This reads presence first and returns $null
        when the field is not there.
    #>
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

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


# ═══════════════════════════════════════════════════════════════════════
#  Direct execution
# ═══════════════════════════════════════════════════════════════════════
#
# This file defines Get-MembershipGap. Run as a script instead of being
# dot-sourced, it used to define the function in a scope that disappeared at
# once, and to ignore its arguments without a word. It now runs the analysis
# when it is given parameters, and says how to use it when it is given none.
# Splatting the automatic $args variable keeps the parameter names.

if ($MyInvocation.InvocationName -ne '.') {
    if ($args.Count -gt 0) {
        Get-MembershipGap @args
    }
    else {
        Write-Warning ("Get-MembershipGap.ps1 defines the Get-MembershipGap function. " +
            "Either dot-source it ('. ./Get-MembershipGap.ps1') and call Get-MembershipGap, " +
            "or run it with parameters ('./Get-MembershipGap.ps1 -GroupId <id> [-IntentPath <path>] [-OutputPath <path>]').")
    }
}
