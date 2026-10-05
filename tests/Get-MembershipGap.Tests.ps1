BeforeAll {
    . "$PSScriptRoot/../Get-MembershipGap.ps1"
}

Describe 'Get-RulePrefix' {

    It 'parses a startsWith rule on device.displayName' {
        $r = Get-RulePrefix -Rule '(device.displayName -startsWith "WKS-")'
        $r.Property | Should -Be 'displayName'
        $r.Operator | Should -Be 'startsWith'
        $r.Value    | Should -Be 'WKS-'
    }

    It 'parses an eq rule on user.department' {
        $r = Get-RulePrefix -Rule '(user.department -eq "Engineering")'
        $r.Property | Should -Be 'department'
        $r.Operator | Should -Be 'eq'
    }

    It 'parses a rule without parentheses' {
        $r = Get-RulePrefix -Rule 'user.department -eq "Sales"'
        $r.Property | Should -Be 'department'
    }

    It 'returns $null for compound rules' {
        $r = Get-RulePrefix -Rule '(device.displayName -startsWith "A") -and (device.accountEnabled -eq true)'
        $r | Should -BeNullOrEmpty
    }

    It 'returns $null for -contains (deliberately unsupported)' {
        $r = Get-RulePrefix -Rule '(device.displayName -contains "WKS")'
        $r | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProximityHint' {

    BeforeAll {
        $script:pat = [PSCustomObject]@{ Property = 'displayName'; Operator = 'startsWith'; Value = 'LAB-SCOPE-' }
    }

    It 'detects a separator omission, the lab under-coverage case' {
        Get-ProximityHint -Name 'LABSCOPE-0002' -Pattern $script:pat | Should -BeLike '*Separator*'
    }

    It 'detects a separator substitution' {
        Get-ProximityHint -Name 'LAB_SCOPE_0005' -Pattern $script:pat | Should -BeLike '*Separator*'
    }

    It 'does not flag case difference (Entra rules are case-insensitive)' {
        Get-ProximityHint -Name 'lab-scope-0006' -Pattern $script:pat | Should -BeNullOrEmpty
    }

    It 'returns $null for an exact prefix match' {
        Get-ProximityHint -Name 'LAB-SCOPE-0001' -Pattern $script:pat | Should -BeNullOrEmpty
    }

    It 'returns $null for unrelated names' {
        Get-ProximityHint -Name 'SRV-DB01' -Pattern $script:pat | Should -BeNullOrEmpty
    }
}

Describe 'Get-MembershipGap' {

    BeforeAll {
        $script:userGroup = @{
            Id = 'g-user'; DisplayName = 'Lab-Scope-Users'
            MembershipRule = '(user.displayName -startsWith "LAB-SCOPE-")'
            MembershipRuleProcessingState = 'On'; GroupTypes = @('DynamicMembership')
        }
        $script:deviceGroup = @{
            Id = 'g-dev'; DisplayName = 'Lab-Scope-Devices'
            MembershipRule = '(device.displayName -startsWith "LAB-SCOPE-")'
            MembershipRuleProcessingState = 'On'; GroupTypes = @('DynamicMembership')
        }

        $script:objects = @(
            @{ Id = 'o-001'; DisplayName = 'LAB-SCOPE-0001' }
            @{ Id = 'o-002'; DisplayName = 'LABSCOPE-0002' }
            @{ Id = 'o-003'; DisplayName = 'LAB-SCOPE-0003' }
            @{ Id = 'o-004'; DisplayName = 'LABSCOPE-0004' }
        )
        $script:members = @(
            @{ Id = 'o-001'; AdditionalProperties = @{ displayName = 'LAB-SCOPE-0001' } }
            @{ Id = 'o-003'; AdditionalProperties = @{ displayName = 'LAB-SCOPE-0003' } }
        )
        $script:policy = @{ Id = 'p-001'; DisplayName = 'Baseline-Win11' }
        $script:assignment = @{
            Target = @{ AdditionalProperties = @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId = 'g-user'
                deviceAndAppManagementAssignmentFilterType = 'none'
            } }
        }

        # Responses of the beta endpoint, as Invoke-MgGraphRequest returns them with
        # -OutputType HashTable.
        $script:statusSucceeded = @{
            id = 'g-user'
            membershipRuleProcessingStatus = @{
                status = 'Succeeded'; errorMessage = $null; lastMembershipUpdated = '2026-09-01T10:00:00Z'
            }
        }
        $script:statusFailed = @{
            id = 'g-user'
            membershipRuleProcessingStatus = @{
                status = 'Failed'
                errorMessage = 'Membership updates could not be evaluated: unsupported property.'
                lastMembershipUpdated = '0001-01-01T00:00:00Z'
            }
        }

        $script:dir = Join-Path $TestDrive 'intent'
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null

        function New-Manifest {
            param($Name, $Complete, $Objects)
            $p = Join-Path $script:dir $Name
            @{ complete = $Complete; description = 'test'; asOf = '2026-08-19T00:00:00Z'; objects = $Objects } |
                ConvertTo-Json -Depth 5 | Set-Content $p
            return $p
        }

        $script:fullManifest = New-Manifest 'full.json' $true @(
            @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
            @{ id = 'o-002'; displayName = 'LABSCOPE-0002'; expectedMember = $true }
            @{ id = 'o-003'; displayName = 'LAB-SCOPE-0003'; expectedMember = $false }
            @{ id = 'o-004'; displayName = 'LABSCOPE-0004'; expectedMember = $false }
        )
        $script:noGapManifest = New-Manifest 'nogap.json' $true @(
            @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
            @{ id = 'o-003'; displayName = 'LAB-SCOPE-0003'; expectedMember = $true }
            @{ id = 'o-004'; displayName = 'LABSCOPE-0004'; expectedMember = $false }
        )
        $script:gapPlusUnresolved = New-Manifest 'gap-unresolved.json' $true @(
            @{ id = 'o-002'; displayName = 'LABSCOPE-0002'; expectedMember = $true }
            @{ id = 'o-999'; displayName = 'GHOST'; expectedMember = $true }
        )
        $script:partialNoGap = New-Manifest 'partial.json' $false @(
            @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
        )
        $script:badId = New-Manifest 'bad-id.json' $true @(
            @{ id = 'o-BOGUS'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
        )

        $script:noCompleteFlag = Join-Path $script:dir 'no-complete.json'
        @{ objects = @(@{ id = 'o-001'; expectedMember = $true }) } | ConvertTo-Json -Depth 5 | Set-Content $script:noCompleteFlag

        $script:stringComplete = Join-Path $script:dir 'string-complete.json'
        '{ "complete": "false", "objects": [] }' | Set-Content $script:stringComplete
    }

    BeforeEach {
        Mock Get-MgGroup { $script:userGroup }
        Mock Get-MgGroupMember { $script:members }
        Mock Get-MgUser { $script:objects }
        Mock Get-MgDevice { $script:objects }
        Mock Get-MgDeviceManagementDeviceCompliancePolicy { $script:policy }
        Mock Get-MgDeviceManagementDeviceCompliancePolicyAssignment { @($script:assignment) }
        Mock Invoke-MgGraphRequest { $script:statusSucceeded }
    }

    Context 'four states, user group' {

        It 'produces all four states' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:fullManifest
            $states = $r.evaluation.state
            $states | Should -Contain 'CorrectCoverage'
            $states | Should -Contain 'UnderCoverage'
            $states | Should -Contain 'OverCoverage'
            $states | Should -Contain 'CorrectExclusion'
        }

        It 'concludes GapEstablished with Complete assessment' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:fullManifest
            $r.conclusion.result             | Should -Be 'GapEstablished'
            $r.assessment.completeness       | Should -Be 'Complete'
        }

        It 'detects objectType user and does not call Get-MgDevice' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:fullManifest
            $r.group.objectType | Should -Be 'user'
            Should -Invoke Get-MgUser -Times 1 -Exactly
            Should -Invoke Get-MgDevice -Times 0 -Exactly
        }
    }

    Context 'device group' {

        BeforeEach { Mock Get-MgGroup { $script:deviceGroup } }

        It 'detects objectType device and does not call Get-MgUser' {
            $r = Get-MembershipGap -GroupId 'g-dev' -IntentPath $script:fullManifest
            $r.group.objectType | Should -Be 'device'
            Should -Invoke Get-MgDevice -Times 1 -Exactly
            Should -Invoke Get-MgUser -Times 0 -Exactly
        }

        It 'produces the same four states on a device group' {
            $r = Get-MembershipGap -GroupId 'g-dev' -IntentPath $script:fullManifest
            $r.summary.rows.UnderCoverage | Should -Be 1
            $r.summary.rows.OverCoverage  | Should -Be 1
        }

        It 'uses device semantics on the policy' {
            Mock Get-MgDeviceManagementDeviceCompliancePolicyAssignment {
                @{ Target = @{ AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = 'g-dev' } } }
            }
            $r = Get-MembershipGap -GroupId 'g-dev' -PolicyId 'p-001' -IntentPath $script:fullManifest
            $r.policy.semantics | Should -BeLike '*device object*'
            $r.policy.semantics | Should -Not -BeLike '*managed devices of that user*'
        }
    }

    Context 'a proven gap survives an incomplete assessment' {

        It 'concludes GapEstablished even with unresolved entries' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:gapPlusUnresolved
            $r.conclusion.result       | Should -Be 'GapEstablished'
            $r.assessment.completeness | Should -Be 'Partial'
            $r.summary.manifestEntries.NotResolved     | Should -Be 1
        }
    }

    Context 'a partial manifest cannot establish absence of gap' {

        It 'concludes CoverageNotDemonstrable when complete is false' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:partialNoGap
            $r.conclusion.result       | Should -Be 'CoverageNotDemonstrable'
            $r.assessment.completeness | Should -Be 'Partial'
        }

        It 'classifies unlisted members as NotInManifest, never OverCoverage' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:partialNoGap
            $r.summary.rows.NotInManifest | Should -Be 1
            $r.summary.rows.OverCoverage  | Should -Be 0
        }
    }

    Context 'unresolved entries suppress over-coverage' {

        It 'does not claim OverCoverage while an entry is unresolved' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:gapPlusUnresolved
            $notInManifest = @($r.evaluation | Where-Object state -EQ 'NotInManifest')
            $notInManifest.Count | Should -BeGreaterThan 0
        }
    }

    Context 'no gap, complete manifest' {

        It 'concludes NoGapEstablished' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.conclusion.result       | Should -Be 'NoGapEstablished'
            $r.assessment.completeness | Should -Be 'Complete'
        }
    }

    Context 'manifest contract' {

        It 'throws when complete is omitted' {
            { Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noCompleteFlag } | Should -Throw '*explicitly declare*'
        }

        It 'throws when complete is a string rather than a boolean' {
            { Get-MembershipGap -GroupId 'g-user' -IntentPath $script:stringComplete } | Should -Throw '*JSON boolean*'
        }

        It 'does not fall back to displayName when an explicit id is wrong' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:badId
            $r.summary.manifestEntries.NotResolved | Should -Be 1
            $r.diagnostics | Where-Object code -EQ 'IntentObjectNotResolved' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'proximity covers manifest objects' {

        It 'produces a separator hint for the under-covered object' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:fullManifest
            $hit = $r.proximity | Where-Object displayName -EQ 'LABSCOPE-0002'
            $hit | Should -Not -BeNullOrEmpty
            $hit.hint | Should -BeLike '*Separator*'
            $hit.evaluationState | Should -Be 'UnderCoverage'
        }
    }

    Context 'assignment filter' {

        It 'raises a diagnostic when a filter is present on the assignment' {
            Mock Get-MgDeviceManagementDeviceCompliancePolicyAssignment {
                @{ Target = @{ AdditionalProperties = @{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    groupId = 'g-user'
                    deviceAndAppManagementAssignmentFilterId = 'f-001'
                    deviceAndAppManagementAssignmentFilterType = 'include'
                } } }
            }
            $r = Get-MembershipGap -GroupId 'g-user' -PolicyId 'p-001' -IntentPath $script:fullManifest
            $r.diagnostics | Where-Object code -EQ 'AssignmentFilterNotEvaluated' | Should -Not -BeNullOrEmpty
            $r.policy.assignmentFilterEvaluated | Should -Be $false
        }

        It 'sets memberOfDirectlyAssignedGroup, not a targeting claim' {
            $r = Get-MembershipGap -GroupId 'g-user' -PolicyId 'p-001' -IntentPath $script:fullManifest
            $under = $r.evaluation | Where-Object state -EQ 'UnderCoverage'
            $under.memberOfDirectlyAssignedGroup | Should -Be $false
            $over = $r.evaluation | Where-Object state -EQ 'OverCoverage'
            $over.memberOfDirectlyAssignedGroup | Should -Be $true
        }
    }

    Context 'no manifest' {

        It 'concludes CoverageNotDemonstrable with Absent completeness' {
            $r = Get-MembershipGap -GroupId 'g-user'
            $r.conclusion.result       | Should -Be 'CoverageNotDemonstrable'
            $r.assessment.completeness | Should -Be 'Absent'
        }

        It 'populates displayName on Observed entries' {
            $r = Get-MembershipGap -GroupId 'g-user'
            $observed = @($r.evaluation | Where-Object state -EQ 'Observed')
            $observed.Count | Should -Be 2
            $observed[0].displayName | Should -Not -BeNullOrEmpty
        }
    }

    Context 'observation freshness is a separate axis from manifest completeness' {

        It 'reports NotDemonstrated freshness when the rule is On' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.freshness        | Should -Be 'NotDemonstrated'
            $r.observation.processingStatus | Should -Be 'Succeeded'
            $r.assessment.completeness      | Should -Be 'Complete'
        }

        It 'never claims the snapshot has converged, even on NoGapEstablished' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.conclusion.result | Should -Be 'NoGapEstablished'
            $r.conclusion.detail | Should -BeLike '*freshness was not independently established*'
        }

        It 'marks freshness Stale and degrades the conclusion when the rule is paused' {
            Mock Get-MgGroup {
                $g = $script:userGroup.Clone()
                $g.MembershipRuleProcessingState = 'Paused'
                $g
            }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.freshness   | Should -Be 'Stale'
            $r.assessment.completeness | Should -Be 'Complete'
            $r.conclusion.result       | Should -Be 'CoverageNotDemonstrable'
            $r.diagnostics | Where-Object code -EQ 'RuleNotActive' | Should -Not -BeNullOrEmpty
        }

        It 'still concludes GapEstablished on a stale snapshot' {
            Mock Get-MgGroup {
                $g = $script:userGroup.Clone()
                $g.MembershipRuleProcessingState = 'Paused'
                $g
            }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:fullManifest
            $r.conclusion.result     | Should -Be 'GapEstablished'
            $r.observation.freshness | Should -Be 'Stale'
        }
    }

    Context 'duplicates and contradictions' {

        BeforeAll {
            $script:dupManifest = Join-Path $script:dir 'dup.json'
            @{ complete = $true; objects = @(
                @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
                @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
                @{ id = 'o-003'; displayName = 'LAB-SCOPE-0003'; expectedMember = $true }
                @{ id = 'o-004'; displayName = 'LABSCOPE-0004'; expectedMember = $false }
            ) } | ConvertTo-Json -Depth 5 | Set-Content $script:dupManifest

            $script:contradictionManifest = Join-Path $script:dir 'contradiction.json'
            @{ complete = $true; objects = @(
                @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $true }
                @{ id = 'o-001'; displayName = 'LAB-SCOPE-0001'; expectedMember = $false }
            ) } | ConvertTo-Json -Depth 5 | Set-Content $script:contradictionManifest
        }

        It 'treats an identical duplicate as inert, not as a resolution failure' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:dupManifest
            $r.summary.manifestEntries.NotResolved     | Should -Be 0
            $r.assessment.completeness | Should -Be 'Complete'
            $r.diagnostics | Where-Object code -EQ 'IntentEntryDuplicate' | Should -Not -BeNullOrEmpty
        }

        It 'counts the duplicate so the declared/resolved gap is explained' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:dupManifest
            $r.intentSource.declaredObjectCount | Should -Be 4
            $r.intentSource.resolvedObjectCount | Should -Be 3
            $r.intentSource.duplicatesIgnored   | Should -Be 1
        }

        It 'does not let a benign duplicate flip the conclusion' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:dupManifest
            $r.conclusion.result | Should -Be 'NoGapEstablished'
        }

        It 'rejects a manifest that contradicts itself about an object' {
            { Get-MembershipGap -GroupId 'g-user' -IntentPath $script:contradictionManifest } |
                Should -Throw '*contradictory expectedMember*'
        }
    }

    Context 'unsupported rule' {

        It 'throws when the object type cannot be determined' {
            Mock Get-MgGroup {
                @{ Id = 'g-x'; DisplayName = 'X'; GroupTypes = @('DynamicMembership')
                   MembershipRule = '(something.else -eq "x")'; MembershipRuleProcessingState = 'On' }
            }
            { Get-MembershipGap -GroupId 'g-x' } | Should -Throw '*Cannot determine object type*'
        }

        It 'accepts Direct Reports syntax as a user group without proximity' {
            Mock Get-MgGroup {
                @{ Id = 'g-dr'; DisplayName = 'DR'; GroupTypes = @('DynamicMembership')
                   MembershipRule = 'Direct Reports for "62e19b97-8b3d-4d4a-a106-4ce66896a863"'
                   MembershipRuleProcessingState = 'On' }
            }
            $r = Get-MembershipGap -GroupId 'g-dr'
            $r.group.objectType | Should -Be 'user'
            $r.proximity.Count  | Should -Be 0
        }
    }

    Context 'non-dynamic group' {

        It 'throws' {
            Mock Get-MgGroup {
                @{ Id = 'g-static'; DisplayName = 'Static'; GroupTypes = @()
                   MembershipRule = $null; MembershipRuleProcessingState = $null }
            }
            { Get-MembershipGap -GroupId 'g-static' } | Should -Throw '*not a dynamic group*'
        }
    }

    Context 'rule processing status, read from the beta endpoint' {

        It 'reads the status from the beta endpoint with an explicit select' {
            $null = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*/beta/groups/g-user*' -and $Uri -like '*$select=*membershipRuleProcessingStatus*'
            }
        }

        It 'keeps freshness NotDemonstrated when the last run succeeded' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.processingStatus | Should -Be 'Succeeded'
            $r.observation.freshness        | Should -Be 'NotDemonstrated'
            $r.conclusion.result            | Should -Be 'NoGapEstablished'
        }

        It 'keeps the gap and names the failure when processing failed' {
            Mock Invoke-MgGraphRequest { $script:statusFailed }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:fullManifest
            $r.conclusion.result            | Should -Be 'GapEstablished'
            $r.summary.rows.UnderCoverage   | Should -Be 1
            $r.observation.processingStatus | Should -Be 'Failed'
            $r.observation.processingError  | Should -BeLike '*unsupported property*'
            $r.observation.freshness        | Should -Be 'Stale'
            $r.conclusion.gapBreakCondition | Should -BeLike '*will not close by waiting*'
            $r.diagnostics | Where-Object code -EQ 'RuleProcessingFailed' | Should -Not -BeNullOrEmpty
        }

        It 'does not establish coverage on a failed group whose population still matches' {
            # The case version 0.1 got wrong: a frozen membership that happens to match
            # the manifest was reported as NoGapEstablished.
            Mock Invoke-MgGraphRequest { $script:statusFailed }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.conclusion.result       | Should -Be 'CoverageNotDemonstrable'
            $r.conclusion.detail       | Should -BeLike '*no longer maintained*'
            $r.assessment.completeness | Should -Be 'Complete'
        }

        It 'reports NotRetrieved and a diagnostic when the status cannot be read' {
            Mock Invoke-MgGraphRequest { throw 'simulated read failure' }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.processingStatus | Should -Be 'NotRetrieved'
            $r.observation.freshness        | Should -Be 'NotDemonstrated'
            $r.conclusion.result            | Should -Be 'NoGapEstablished'
            (@($r.sources) | Where-Object apiVersion -EQ 'beta').retrieved | Should -Be $false
            $r.diagnostics | Where-Object code -EQ 'ProcessingStatusNotRetrieved' | Should -Not -BeNullOrEmpty
        }

        It 'reports NotReported when the service returns no status' {
            Mock Invoke-MgGraphRequest { @{ id = 'g-user'; membershipRuleProcessingStatus = $null } }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.processingStatus | Should -Be 'NotReported'
            (@($r.sources) | Where-Object apiVersion -EQ 'beta').retrieved | Should -Be $true
        }
    }

    Context 'the last membership change is a date only when it can be one' {

        BeforeEach {
            Mock Get-MgGroup {
                $g = $script:userGroup.Clone()
                $g.CreatedDateTime = [datetime]::new(2026, 9, 23, 10, 53, 0, [System.DateTimeKind]::Utc)
                $g
            }
        }

        It 'marks a value earlier than the group itself as unusable and keeps it raw' {
            Mock Invoke-MgGraphRequest { $script:statusFailed }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.lastMembershipUsable  | Should -BeOfType [bool]
            $r.observation.lastMembershipUsable  | Should -Be $false
            $r.observation.lastMembershipUpdated | Should -BeLike '0001-01-01*'
        }

        It 'treats another placeholder the same way, without a list of known values' {
            Mock Invoke-MgGraphRequest {
                @{ membershipRuleProcessingStatus = @{ status = 'NotStarted'; errorMessage = $null; lastMembershipUpdated = '2000-01-01T08:00:00Z' } }
            }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.lastMembershipUsable | Should -BeOfType [bool]
            $r.observation.lastMembershipUsable | Should -Be $false
        }

        It 'accepts a value later than the creation of the group' {
            Mock Invoke-MgGraphRequest {
                @{ membershipRuleProcessingStatus = @{ status = 'Succeeded'; errorMessage = $null; lastMembershipUpdated = '2026-09-23T10:53:34Z' } }
            }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.lastMembershipUsable | Should -BeOfType [bool]
            $r.observation.lastMembershipUsable | Should -Be $true
        }

        It 'does not decide when the creation of the group is unknown' {
            Mock Get-MgGroup { $script:userGroup }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.observation.lastMembershipUsable | Should -BeNullOrEmpty
        }
    }

    Context 'report envelope, schema 2' {

        It 'declares the schema version, the tool version and the tenant' {
            Mock Get-MgContext { @{ TenantId = 't-0001' } }
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            $r.metadata.schemaVersion | Should -Be '2'
            $r.metadata.toolVersion   | Should -Be '0.2.0'
            $r.metadata.tenantId      | Should -Be 't-0001'
        }

        It 'records the Graph modules loaded in the session' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            @($r.metadata.graphModules).Count   | Should -BeGreaterThan 0
            @($r.metadata.graphModules)[0].name | Should -BeLike 'Microsoft.Graph.*'
        }

        It 'keeps rows and manifest entries apart in the summary' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:gapPlusUnresolved
            $r.summary.rowUnit                     | Should -Be 'object'
            $r.summary.manifestEntries.NotResolved | Should -Be 1
            $r.summary.rows.PSObject.Properties.Name | Should -Not -Contain 'NotResolved'
        }

        It 'names the API version behind each source' {
            $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:noGapManifest
            @($r.sources).apiVersion | Should -Contain 'v1.0'
            @($r.sources).apiVersion | Should -Contain 'beta'
        }
    }

    Context 'independence from the caller strict mode' {

        BeforeAll {
            $script:idOnly = Join-Path $script:dir 'id-only.json'
            '{ "complete": true, "objects": [ { "id": "o-001", "expectedMember": true } ] }' | Set-Content $script:idOnly
        }

        It 'reads a manifest whose entries carry only an id under Set-StrictMode -Version Latest' {
            Set-StrictMode -Version Latest
            try {
                $r = Get-MembershipGap -GroupId 'g-user' -IntentPath $script:idOnly
            }
            finally {
                Set-StrictMode -Off
            }
            $r.intentSource.resolvedObjectCount | Should -Be 1
        }
    }

    Context 'running the file directly' {

        BeforeAll {
            $script:analyzerPath = (Resolve-Path "$PSScriptRoot/../Get-MembershipGap.ps1").Path
        }

        # Run with &, the file gets a script scope of its own. A mock body that reads
        # $script:userGroup then resolves it in that new scope, finds nothing, and the
        # analyzer receives $null. The mocks of this context therefore return literal
        # objects and read no script-scoped variable.
        BeforeEach {
            Mock Get-MgGroup {
                @{
                    Id = 'g-user'; DisplayName = 'Lab-Scope-Users'
                    MembershipRule = '(user.displayName -startsWith "LAB-SCOPE-")'
                    MembershipRuleProcessingState = 'On'; GroupTypes = @('DynamicMembership')
                }
            }
            Mock Get-MgGroupMember {
                @(
                    @{ Id = 'o-001'; AdditionalProperties = @{ displayName = 'LAB-SCOPE-0001' } }
                    @{ Id = 'o-003'; AdditionalProperties = @{ displayName = 'LAB-SCOPE-0003' } }
                )
            }
            Mock Get-MgUser {
                @(
                    @{ Id = 'o-001'; DisplayName = 'LAB-SCOPE-0001' }
                    @{ Id = 'o-002'; DisplayName = 'LABSCOPE-0002' }
                    @{ Id = 'o-003'; DisplayName = 'LAB-SCOPE-0003' }
                    @{ Id = 'o-004'; DisplayName = 'LABSCOPE-0004' }
                )
            }
            Mock Invoke-MgGraphRequest {
                @{ membershipRuleProcessingStatus = @{ status = 'Succeeded'; errorMessage = $null; lastMembershipUpdated = '2026-09-01T10:00:00Z' } }
            }
        }

        It 'runs the analysis with the parameters it is given' {
            $r = & $script:analyzerPath -GroupId 'g-user' -IntentPath $script:noGapManifest 6>$null
            $r.conclusion.result | Should -Be 'NoGapEstablished'
            # Named parameters must reach the function by name. Passed positionally,
            # '-GroupId' itself would become the group id.
            Should -Invoke Get-MgGroup -Times 1 -Exactly -ParameterFilter { $GroupId -eq 'g-user' }
        }

        It 'says how to use it when it is given no parameter' {
            $output = & $script:analyzerPath 3>&1
            ($output | Out-String) | Should -BeLike '*dot-source*'
        }
    }
}
