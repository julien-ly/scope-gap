# Evidence: a dynamic group that stopped following its rule

These are the readings behind the paragraph "A failed rule can leave the group frozen" in the main README. They come from a lab tenant, between 23 September and 5 October 2026. They are raw outputs of the lab scripts and of `scope-gap`, anonymized as described at the end, and nothing else in them was edited.

They establish one failure, observed once, on one pair of groups. What they do not establish is listed further down.

## `run1-create/`: creating a group through Microsoft Graph

Run `20260923105301`, 23 September 2026. Rule under test `user.propertyThatDoesNotExist -eq null`, control rule `user.department -eq null`, two paths in the same run.

Created with processing `On`, the invalid rule is rejected: HTTP 400, `DynamicGroupQueryParseError`, `Unsupported property 'propertyThatDoesNotExist'` (`groups[0]`, and the probe recorded in the notes with its request id).

Created with processing `Paused`, the same rule is accepted and stored exactly as sent. Switching the group to `On` is accepted. The processing status then reads `Failed`, with `Membership updates could not be evaluated: unsupported property.` (`groups[2]`). That group was never evaluated successfully, and the portal shows it with no members (notes).

The control rule reaches `Succeeded` on both paths.

The notes record the portal side: creating a group with the same rule is refused with the property named, and the overview of the failed group shows a warning banner. Two entries in that file are command templates recorded by mistake, an ellipsis and a bracketed placeholder. They carry no observation and are kept so that the file is complete.

## `run2-edit/`: editing an existing group in the portal

Run `20260923113815`, 23 to 26 September 2026.

Two groups are created with `user.department -eq null`. Both reach `Succeeded` with the same eight members, which is every user in the tenant at that time (`phases.setup`). The test group is then paused; the control stays `On`.

The invalid rule is entered in the portal on both groups. On the control, the save is refused (note 1). On the paused group, it is stored (note 2). The message the portal displayed on that save was not captured; the storage is established by the API read in `phases.checks`, where the stored rule is the invalid one.

The test group is resumed (`phases.resume`). Its status reads `NotStarted` for the fifteen minutes the script polled, and `Failed` with the same message from relecture 3 onwards. When the failure happened between those two readings is not known.

On 26 September a ninth user, `dynlab-user9`, is created as a disabled account with an empty department (note 4). From relecture 4 onwards the control has nine members, the eight plus that user. The test group has the same eight object identifiers in every one of the thirteen relectures.

## `scope-gap/`: the analyzer against the two groups

Two manifests, both complete: the nine users (`scopegap-intent-dynlab-edit.json`) and the eight original users (`scopegap-intent-dynlab-edit-8.json`). They are shipped byte for byte as the reports hashed them, which `tests/Repository.Tests.ps1` checks.

`scopegap-v01-*`, version 0.1.0, 4 October 2026, eight days after the ninth user was created. On the failed group with the eight original users (`test-8`), version 0.1.0 concludes `NoGapEstablished`. With the nine users (`test-9`), it finds one object under-covered: `dynlab-user9`, still absent. The control (`control-9`) has no gap.

`scopegap-v021-*`, version 0.2.1, 5 October 2026. The same three passes. `test-8` concludes `CoverageNotDemonstrable`, with processing `Failed` and freshness `Stale`. `test-9` keeps the same gap, `dynlab-user9` still absent nine days after its creation, and adds a `RuleProcessingFailed` diagnostic carrying the error message. `control-9` reads processing `Succeeded` and still has no gap. On the failed group the last membership change reads `0001-01-01T00:00:00Z`, earlier than the creation of the group, and is marked unusable; on the control it reads 26 September 2026 at 09:09:15 UTC, the change recorded when the ninth user joined, and is marked usable.

## What these files do not establish

How long the failure takes to appear. It was observed between fifteen minutes and two days after the resume, with no control on that path.

Whether the failure would clear without a change to the rule. The status does not say, and the lab did not test it.

Any other cause of failure. One error message was observed.

That a delegated session needs nothing beyond the permissions `scope-gap` documents. The token used carried broader scopes already consented in the tenant, so the runs are consistent with the documentation without isolating it.

## Anonymization

Applied to the raw text, so that everything else in each file is unchanged:

- `account` is replaced by `lab-operator`.
- Local file paths in `notesFile` and `intentSource.path` are reduced to the file name.
- In the `scope-gap` reports, the display names of the eight original users are replaced by stable labels, assigned in the lexicographic order of their object identifiers.
- In the notes, the user principal name of the ninth user loses its domain.

`dynlab-user9` keeps its name: it is an account created for the lab, and the name appears in the manifests, which cannot change since the reports record their hashes. Object identifiers, group identifiers and the tenant identifier are kept. Their consistency from one file to the next is what these files show.

| Label | Object identifier |
|---|---|
| user-01 | `076e3f09-e9b9-4d73-9f20-706e093773dc` |
| user-02 | `4b7eb386-2a02-4a11-a2c9-71bc0f5658bb` |
| user-03 | `5173b363-50b4-42eb-9aec-bdf805033c6f` |
| user-04 | `713a26dd-c446-4afa-b989-8463bf3f8666` |
| user-05 | `bacb4928-983e-47b2-be6b-0e6bba539ebf` |
| user-06 | `bca35ea2-65e0-42a5-a080-f4156bcc000e` |
| user-07 | `d04d8bb9-9798-4f03-9bb9-8ed1935a0b00` |
| user-08 | `dcb06df7-c781-4584-b05a-e818990e10f8` |
| dynlab-user9 | `9ab19793-7d2f-43d5-a65b-65d6f147f849` |
