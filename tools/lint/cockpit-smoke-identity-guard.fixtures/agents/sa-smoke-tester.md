---
name: sa-smoke-tester
description: FIXTURE, not an agent — a minimal well-formed per-module smoke procedure (gate G3).
---

<!--
FIXTURE for tools/lint/cockpit-smoke-identity-guard.sh, check [4]. See the sibling sa-tester.md
fixture for why these exist. This one carries the G3 rule set, which is the G4 set minus the two
rules that belong to milestone work only (impersonated capability sampling, and the browser/ttyd
warning) — so the control run also proves the guard applies a PER-FILE rule set rather than one
blanket list.

It states the identity requirement in the second accepted phrasing ("the identity every step ran
under") so the identity-ledger alternation is exercised too, not just its first branch.
-->

Every attendee-typed command runs in the real cockpit:

```
oc exec -n <showroom-ns> deploy/showroom-<userN> -c terminal -- bash -ic '<the command as written in the lab>'
```

Confirm the terminal's own identity before anything else:

```
oc exec -n <showroom-ns> deploy/showroom-<userN> -c terminal -- bash -ic 'oc whoami; command -v ws; echo $HOME'
```

Run the mechanical gate first: `tools/ws/ws smoke <module> <userN>`. Red = stop and report.

Deliberate negative examples ("you'll get Forbidden here") MUST run as the attendee.

Return the identity every step ran under, with the cockpit pod name and a named exception for any
step that could only run as admin.
