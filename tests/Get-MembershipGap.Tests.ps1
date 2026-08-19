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
            $r.summary.UnderCoverage | Should -Be 1
            $r.summary.OverCoverage  | Should -Be 1
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
            $r.summary.NotResolved     | Should -Be 1
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
            $r.summary.NotInManifest | Should -Be 1
            $r.summary.OverCoverage  | Should -Be 0
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
            $r.summary.NotResolved | Should -Be 1
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
            $r.observation.processingStatus | Should -Be 'NotRetrieved'
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
            $r.summary.NotResolved     | Should -Be 0
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
}
