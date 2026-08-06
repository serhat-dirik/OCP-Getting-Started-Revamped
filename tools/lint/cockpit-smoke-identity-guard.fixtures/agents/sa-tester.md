---
name: sa-tester
description: FIXTURE, not an agent — a minimal well-formed MILESTONE gate procedure (G4).
---

<!--
FIXTURE for tools/lint/cockpit-smoke-identity-guard.sh, check [4]. Nothing loads this file as an
agent; it exists so CI — which never sees the real maintainer-local procedures — can still prove
that each rule's detector is not blind.

Every rule the roster declares for a G4 procedure appears exactly ONCE below, so a single sed can
remove exactly one of them and the canary can assert that the guard names THAT rule and no other.
Adding a second occurrence of any marker silently weakens the corresponding canary.
-->

Every attendee-typed command runs where the attendee types it:

```
oc exec -n ogsr-showroom deploy/showroom-<userN> -c terminal -- bash -ic '<the command exactly as the lab writes it>'
```

Prove the terminal is who you think it is before collecting a single result:

```
oc exec -n ogsr-showroom deploy/showroom-<userN> -c terminal -- bash -ic 'oc whoami; command -v ws; echo $HOME'
```

Drive that terminal from Bash, never through a browser: a browser-automation pane cannot deliver the
Enter keystroke to the ttyd web terminal, so the command sits on the prompt line unexecuted while the
screenshot reads as if it ran.

Re-run the mechanical gate yourself rather than trusting the output pasted into a brief:
`tools/ws/ws smoke <module> <userN>`.

Deliberate negative examples run as the attendee, always — in the cockpit, or impersonated with both
flags literal: `--as=user3 --as-group=workshop-attendees`.

Open the Milestone Test Report with the identity ledger, and tag every finding with the identity it
was measured under.
