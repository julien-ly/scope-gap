# scope-gap

A dynamic group controls who receives a compliance policy, a configuration baseline, local administrator password management and endpoint detection enrollment. The group membership depends on a rule. The rule evaluates a property. The property is produced by a human gesture, a sync engine, or a batch job whose output no one audits.

This tool reports what the group captures, what it misses, and whether an object is a member of a group that a policy is directly assigned to.

It does not administer, modify, recommend or decide anything. It establishes.

## What it shows

A four-state matrix crossing expected membership against observed membership.

**Correct coverage.** The object is expected in the group and is a member.
**Under-coverage.** The object is expected in the group and is not a member.
**Over-coverage.** The object is in the group but is not expected.
**Correct exclusion.** The object is not expected and is not a member.

Two further states exist for objects the matrix cannot classify. **Not in manifest**, when a group member is absent from a manifest that does not claim to be exhaustive or that has unresolved entries. **Observed**, when no manifest was provided at all.

Supports dynamic user groups and dynamic device groups. The object type is detected from the membership rule. For user groups, Entra ID P1 is required for the users in scope of the dynamic rule.

## Three axes, reported separately

A proven gap, an incomplete manifest and a membership snapshot of unknown freshness are three different facts. The report keeps them apart.

**Conclusion.**
`GapEstablished` at least one object is under-covered or over-covered.
`NoGapEstablished` the manifest is complete, every entry resolved, and every object in its expected state.
`CoverageNotDemonstrable` no gap was proven, and the assessment could not cover the whole population.

**Assessment completeness**, a property of the manifest.
`Complete` manifest declared complete and fully resolved.
`Partial` manifest incomplete, or entries unresolved. Reasons are listed.
`Absent` no manifest provided.

**Observation freshness**, a property of the membership snapshot.
`Stale` rule processing is not enabled, so the retrieved membership may predate the current rule.
`NotDemonstrated` rule processing is enabled, but convergence was not verified.

Freshness is never asserted as good. `membershipRuleProcessingState` set to `On` only states that processing is enabled; Entra tracks convergence separately (`Evaluating`, `Processing`, `Update complete`, `Processing error`, `Not started`). This version does not retrieve that status, so it reports `NotDemonstrated` rather than claiming the snapshot has converged.

A gap that has been proven does not disappear because the rest of the population could not be assessed. `GapEstablished` with `Partial` completeness is a normal and useful result. Conversely `NoGapEstablished` reads as an absence of gap in the retrieved snapshot, not as a guarantee about a converged one.

`CoverageNotDemonstrable` is not a degraded mode. It is a first-class result, and probably the most frequent. A report stating that the organisation cannot demonstrate which population a control covers is stronger than a list of misnamed objects, and it resists contradiction better.

All conclusions are bounded to the analyzed path. The report never states that an object is unprotected, only that it is not a member of this group. Other assignment paths are not evaluated.

## What would make this redundant

Referential integrity between a rule and an authoritative source would not be enough: a rule can be logically too narrow, an intent can drift, a population can be omitted, and a membership can be read before it has converged. Any of those still produces silent under-coverage.

The tool becomes redundant when the platform natively compares observed dynamic-group membership against an independent authoritative population and reports under-coverage, over-coverage and assessment completeness.

## Requirements

PowerShell 7 or later. Microsoft Graph PowerShell SDK modules: `Microsoft.Graph.Groups`, `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.DeviceManagement`, `Microsoft.Graph.Users`. Install them at a single matching version; mixed versions of the SDK fail to load.

**Analyzer, read-only.** `Group.Read.All`, `Device.Read.All`, `User.Read.All`, `DeviceManagementConfiguration.Read.All`. Nothing more; the analyzer never writes.

**Lab scripts, write, test tenant only.** `Directory.AccessAsUser.All`, `Group.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`, plus a directory role on the signed-in account. Intune Administrator is the simplest choice. See the Lab section for why `Device.ReadWrite.All` is not enough.

No additional licence is required for device groups. For user dynamic groups, Entra ID P1 is required for the users in scope of the rule.

## Usage

```powershell
Connect-MgGraph -Scopes Group.Read.All, Device.Read.All, User.Read.All, DeviceManagementConfiguration.Read.All

. ./Get-MembershipGap.ps1

# Without a manifest: reports members and concludes CoverageNotDemonstrable
Get-MembershipGap -GroupId '<group-object-id>'

# With a manifest: produces the four-state matrix and a conclusion
Get-MembershipGap -GroupId '<group-object-id>' -IntentPath samples/intent.json

# With a manifest and a policy: adds the direct assignment check
Get-MembershipGap -GroupId '<group-object-id>' -PolicyId '<policy-id>' -IntentPath samples/intent.json

# Write the report to a file
Get-MembershipGap -GroupId '<group-object-id>' -IntentPath samples/intent.json -OutputPath report.json
```

The output is a JSON object. The terminal displays a summary; this is not a second format.

## Intent manifest

A JSON file declaring the expected population. Each entry carries a `displayName` or an `id`, and an `expectedMember` boolean.

```json
{
  "description": "Expected workstation population for compliance baseline.",
  "complete": true,
  "asOf": "2026-08-19T00:00:00Z",
  "objects": [
    { "displayName": "WKS-PC001", "expectedMember": true },
    { "id": "d04d8bb9-9798-4f03-9bb9-8ed1935a0b00", "expectedMember": false }
  ]
}
```

**`complete` is mandatory and never inferred.** It states whether the manifest lists the entire population. When `true`, a group member absent from the manifest is over-coverage. When `false`, that member is `NotInManifest` and the assessment is `Partial`, because a partial manifest cannot establish over-coverage and cannot establish the absence of a gap. An omitted `complete` field raises an error rather than defaulting to `true`: a tool about unstated assumptions does not make one about its own reference.

**An explicit `id` is authoritative and has no fallback.** If an entry declares an `id` that does not exist in the directory, the entry is unresolved. It does not fall back to `displayName`, because resolving a different object that happens to carry the same name would be worse than not resolving at all.

**A self-contradicting manifest is rejected.** Two entries for the same object with opposite `expectedMember` values raise an error. Keeping the first silently would let an invalid manifest produce a confident claim about exactly the object it disagrees with. An identical duplicate is inert: it raises an informational diagnostic and counts as neither a resolution failure nor a degradation.

**Unresolved entries suppress over-coverage.** While any declared entry fails to resolve, extra group members are reported as `NotInManifest` rather than over-coverage, since one of them may be the object that failed to resolve.

The manifest cannot be derived from the rule being audited. It requires an independent reference: an inventory, a naming standard, a fleet register, a business list. If the reference population is produced by the mechanism being evaluated, the tool reproduces the blind denominator it claims to reveal.

The report records the manifest `description`, `asOf` date and SHA-256 hash, so that a given report establishes which version of the intent was confronted with which observed state.

## Policy verification

The tool can optionally verify that an Intune device compliance policy carries a **direct assignment to the analyzed group**. That is the entire claim.

The evaluation field is named `memberOfDirectlyAssignedGroup`. `true` means the object is a member of the group and the policy has a direct assignment to that group. It does not mean the object is targeted, evaluated, or compliant.

For a device group, the report establishes that the device object is a member of a directly assigned group. Whether the policy is evaluated on that device depends on enrolment, platform, assignment filters, exclusions and check-in state.

For a user group, the report establishes that the user is a member of a directly assigned group. Intune uses a user assignment to evaluate the managed devices of that user. The user object is not itself the subject of the compliance policy.

If the assignment carries an assignment filter, the report records `assignmentFilterId` and `assignmentFilterType`, sets `assignmentFilterEvaluated` to `false`, and raises an `AssignmentFilterNotEvaluated` diagnostic. A filter can include or exclude objects on top of the group assignment, so its presence bounds the claim further.

## Diagnostics

Warnings and notices generated during execution are captured in the `diagnostics` array of the JSON report. The terminal also shows them, but the JSON is the artifact of proof. Someone who receives only the report file sees the same reservations as the operator who ran the tool.

## Proximity detection

When the membership rule is a single expression using `-startsWith` or `-eq` on `displayName`, the tool looks for objects outside the group whose names are close to the pattern: separator differences, substring matches at the wrong position. These appear in a separate `proximity` section, carry the object's evaluation state when it has one, and are labelled as triage hints, not established findings.

The scan covers every object outside the group, including objects declared in the manifest. The under-covered object is precisely the one most likely to carry a near-miss name.

Entra dynamic membership string operations are case-insensitive. A case difference does not produce a membership gap and is not flagged.

Proximity is not available for compound rules, for properties other than `displayName`, for `-contains` (no defensible signal), or for the `Direct Reports for` syntax. Membership comparison still works in all of those cases.

The recorded run shows the limit that matters. Its under-covered object, `PC-NOPREFIX-002`, carries no form of the expected prefix at all: normalized it reads `pcnoprefix002`, which does not begin with `labwks`. It is outside what the heuristic looks at, not below its threshold. The gap is established from the intent manifest and is unaffected. An empty `proximity` section is therefore not evidence that naming drift is absent.

## Lab

The `lab/` directory contains scripts that create and remove a test environment in a tenant. They write objects and declare it. They are not the analyzer.

```powershell
Connect-MgGraph -Scopes Directory.AccessAsUser.All, Group.ReadWrite.All, DeviceManagementConfiguration.ReadWrite.All

./lab/New-LabEnvironment.ps1
# wait for dynamic group evaluation (several minutes)
./lab/Remove-LabEnvironment.ps1
```

`POST /devices` has a narrow contract and both halves of it are required. The permission is `Directory.AccessAsUser.All`, delegated only: it is the sole delegated permission for the operation, no higher-privileged one exists, and application permissions are not supported at all. `Device.ReadWrite.All` does not grant device creation, and an app-only token cannot perform it in any tenant. On top of that, the signed-in account must hold a supported directory role; the built-in roles documented as sufficient are Intune Administrator and Windows 365 Administrator.

`Authorization_RequestDenied` on `New-MgDevice` therefore means one of those two halves is missing, and says nothing about the tenant. The script checks the scopes before creating anything and names what is absent.

The compliance policy calls later in the script do not carry the same contract. Their reference documents `DeviceManagementConfiguration.ReadWrite.All` and names no directory role; Intune RBAC governs them, but the API reference does not enumerate which roles suffice. Intune Administrator covers both paths. If device creation succeeds and the policy call fails, the subject is Intune RBAC, not the device contract.

`Directory.AccessAsUser.All` grants the signed-in user's full directory access. This lab belongs in a test tenant and nowhere else. The analyzer needs none of it.

The cleanup inventory is written before anything is created and updated after each object, so a failure part-way through still leaves a complete list of what exists. The removal script deletes that inventory only once every object has been removed or confirmed absent; if a deletion fails for any other reason, the inventory is kept, because it is the only record of what remains.

The lab shipped here is device-based. The analyzer is not: its user path is exercised against a separately prepared dynamic user group, and the mechanism, the matrix and the conclusions are identical on both.

## Limits

One group, and optionally one compliance policy. Configuration profiles, endpoint security policies and conditional access policies are not covered.

No claim about enforcement. Only membership, and the presence of a direct group assignment.

Assignment filters are detected and reported, never evaluated.

Objects resolved by `displayName` are skipped when several objects share the name.

## Structure

```
Get-MembershipGap.ps1          The analyzer. Read-only.
lab/New-LabEnvironment.ps1     Creates the test defect. Writes to the tenant.
lab/Remove-LabEnvironment.ps1  Removes the test objects.
tests/Get-MembershipGap.Tests.ps1   Behaviour tests for the analyzer.
tests/Repository.Tests.ps1         Parse checks over every script, and sample
                                   consistency. No tenant connection required.
samples/intent.json            Manifest showing the format, with the four states annotated.
samples/lab-intent.json        The manifest used in the recorded run below.
samples/output.json            The report from that run, against a real tenant.
```

## Recorded run

`samples/output.json` is not illustrative. It is the report produced by one execution against a real tenant on 19 August 2026, over the four device objects the lab creates, with the compliance policy assigned to the group. The lab ran end to end with no manual step: the objects, the assignment through the assign action, the read-back confirmation and the manifest all came from `New-LabEnvironment.ps1`.

It records `GapEstablished` with `Complete` completeness and `NotDemonstrated` freshness: one object correctly covered, one under-covered because it does not carry the naming convention, one over-covered because it does, one correctly excluded.

`proximity` is empty in that run, and that is the expected result. `PC-NOPREFIX-002` is under-covered but carries no near-miss form of the prefix: normalized it reads `pcnoprefix002`, which does not begin with `labwks`. Proximity detects separator faults, not names outside the convention. The most common cause of under-coverage produces no hint.

The provenance claim is verifiable. `intentSource.sha256` is the SHA-256 of `samples/lab-intent.json` as shipped. The hash covers bytes, not content: that manifest was written on Windows with CRLF line endings, and the same content written with LF hashes differently. A hash comparison is only meaningful against the same writing platform.

Running the lab regenerates both files. `samples/lab-intent.json` is tracked and rewritten on every lab execution, so a clone that runs the lab will see a tracked file change. That is expected, not corruption: the shipped pair is a frozen record of one run, and running the lab replaces it with a record of yours.

## Licence

MIT.
