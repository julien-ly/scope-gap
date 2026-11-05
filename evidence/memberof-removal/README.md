# Evidence: removals from a memberOf source group are propagated

These are the readings behind [MicrosoftDocs/entra-docs#2153](https://github.com/MicrosoftDocs/entra-docs/pull/2153), which proposes to drop member removals from one of the [preview limitations](https://learn.microsoft.com/entra/identity/users/groups-dynamic-rule-member-of#preview-limitations) listed on the `memberOf` page of Microsoft Learn. That limitation reads: "Membership of a memberOf dynamic group doesn't automatically update when a child group is deleted or when members are removed from a child group. The affected users or devices remain members of the memberOf dynamic group until the rule is modified."

They come from a lab tenant with Microsoft Entra ID P1, without Microsoft Entra ID Governance, on 3 and 5 November 2026. The journal is the raw output of the lab commands. Nothing in it was edited.

They establish two removals and one addition, each observed once, on one pair of groups. What they do not establish is listed further down.

## Setup

Run `20261103155322`, created on 3 November 2026:

- two disabled lab users: `dynlab-mo-a-20261103155322`, with the department `dynlab-mo-20261103155322`, and `dynlab-mo-b-20261103155322`, with no department;
- an assigned security group, the source group (a child group in the wording of Learn), containing A;
- the test group, `dynlab-mo-test-20261103155322`, with the rule `user.memberof -any (group.objectId -in ['<object ID of the source group>'])`;
- the control group, `dynlab-mo-temoin-20261103155322` (`temoin` is French for control), with the rule `user.department -eq "dynlab-mo-20261103155322"`.

The control depends on the department attribute only.

## The journal

`dynlab-mo-20261103155322-lectures.jsonl` has one JSON object per line. The lab commands are written in French, and so are the field names and the action descriptions:

- `Lu`: when the line was written, in UTC.
- `Groupe`: the display name of the group read, or `MODIFICATION` for an action. An action line is written right after the command returns, and its `Etat` describes the action.
- `Etat`: `membershipRuleProcessingState`.
- `Statut`: `membershipRuleProcessingStatus.status`, read from the beta endpoint.
- `MajMembres`: `membershipRuleProcessingStatus.lastMembershipUpdated`, serialized as `\/Date(n)\/`, where `n` is the number of milliseconds since 1 January 1970 UTC.
- `Erreur`: `membershipRuleProcessingStatus.errorMessage`.
- `Membres`: the display names of the members, sorted, read from `/v1.0/groups/{id}/members`.

The file is stored byte for byte as Windows PowerShell 5.1 wrote it: Windows-1252, CRLF line endings, no byte order mark. Its only non-ASCII character is the e with an acute accent (0xE9) in the action descriptions. SHA-256: `84C9B606DE5ABEF477409FD957D56F7BF54F4EFB873A8F9E3FC54415F38A72DB`.

## What the journal shows

Times are in UTC, on 5 November 2026 unless stated. "Updated" is the decoded `MajMembres`. The reading itself came later, at the `Lu` time of its line.

| Lines | Action | Test group | Control group |
|---|---|---|---|
| 1-2 | None, first reading at 13:12:09 | A, updated 3 November at 14:58:38 | A, updated 3 November at 14:58:39 |
| 3-5 | 13:14:47: B added to the source group, department set | A and B, updated 13:13:27 | A and B, updated 13:15:37 |
| 6-8 | 13:24:04: A removed from the source group, department changed | B, updated 13:24:13 | B, updated 13:24:13 |
| 9-11 | 13:54:56: A added to the source group, no attribute changed | A and B, updated 13:55:32 | B, unchanged |
| 12-14 | 13:56:57: B removed from the source group, no attribute changed | A, updated 13:57:06 | B, unchanged |
| 15-17 | 14:16:53: A removed from the source group, no attribute changed | No member, updated 14:17:05 | B, unchanged |

`Statut` reads `Succeeded` and `Erreur` is empty in every reading.

The first two actions each changed a membership and the department of the same user. Learn states that "when the attributes of a user or a device change, the system evaluates all rules for dynamic membership groups in a directory to see if the change would trigger any group additions or removals" ([groups-dynamic-membership](https://learn.microsoft.com/entra/identity/users/groups-dynamic-membership#considerations-for-dynamic-membership-groups)). These two actions therefore do not isolate the effect of the membership change, and are kept so that the journal is complete. The action line at 13:14:47 was written after both commands, and the test group had already been updated at 13:13:27, so the order of the two commands and that update is not established.

The last three actions changed a membership only: no attribute was changed, and the control group did not change. The test group followed each of them, 36, 9 and 12 seconds after the action line.

## What these files do not establish

The deletion of a source group. It was not tested, and #2153 leaves that case of the limitation unchanged.

Other configurations: several source groups, device groups, groups synced from Active Directory, large groups, other tenants. One pair of groups with direct members was observed.

Whether member removals went unprocessed earlier in the preview.

When the end of the preview takes effect in this tenant. Learn states that groups that use `memberOf` stop updating after 3 November 2026; on 5 November, this test group still followed its source group. Whether the stop, once it happens, shows in the processing status or in `lastMembershipUpdated` is not known.

## Anonymization

None. The journal contains no object identifier, account, domain, tenant identifier or local path. The user and group names are those the lab gave to objects it created for this test.
