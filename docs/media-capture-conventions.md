# Media-capture conventions

Rules for **any** attendee-facing media: screenshots, terminal `.cast` recordings, GIFs, MP4
walkthroughs — whether shot by hand, through `tools/media/capture.py`, or in a live demo
recording. Every rule below comes from a real incident, not a hypothetical, because a rule
without its reason gets optimised away by the next person under time pressure. Read this once;
it is a three-minute read.

This is the policy layer. For how the screenshot driver actually works (jobs, waits, login,
profiles), see `tools/media/README.md` and `tools/media/RUNBOOK.md` — this file does not repeat
their mechanics, only the rules that apply regardless of which tool did the capturing.

## 1. The privacy guard cannot see inside media — the manifest row is the only gate

CI's privacy guard runs `git grep`: text only. A credential rendered inside a PNG, an MP4, or a
recorded terminal `.cast` passes every automated check this repo has, every time, silently.
There is no equivalent scanner for pixels or asciicast frames, and none is coming — reading a
manifest row before you press record is the whole control.

Three manifest rows were found pointing the wrong way in one pass: one asked to shoot a Secret
with **"Reveal values" ON**; one asked to **record a redirect "after signing in as
adjuster/parasol"** — which means filming a password being typed into a login form; one demo
cast script carried `client_secret=` in its curl lines, headed for a recording.

**Rule:** any manifest or job row that names a UI action which would expose a decoded secret, a
password field, or a client secret must state the safe alternative *in the row itself*, not rely
on the person capturing to notice:

- masked/base64 display, **"Reveal values" left OFF** (Secrets), never toggled on for the shot
- a fabricated fixture value where the lab's own secret is meant to be visible (e.g. a teaching
  client-secret that is not a real credential) — say so, so a reviewer doesn't have to guess
- credential entry kept **out of frame** — start the recording after the login form is dismissed,
  or cut before the keystrokes

If a row doesn't say which of these applies, treat that as the row being wrong, not as
permission to proceed and use judgement live.

## 2. Ephemeral cluster domains in screenshots are fine — be precise about the boundary

Owner decision, 2026-07-26. Captures inevitably carry the cluster they were taken on (Gitea, Argo
CD, Route URLs); those clusters are destroyed after use; and doctoring the exact fields an
attendee must read to follow along makes worse teaching material, not better.

What stays forbidden **everywhere, screenshots included**: a visible token, password, personal
email, or API key. Check every image for these before committing — CI cannot, per rule 1.

People over-redact when this line is vague, so hold it precisely: cluster domain — fine.
Anything an attacker or a person could reuse — never. `tools/media/README.md` has the mechanics
(the Gitea locale gotcha, the `require_in_frame` check) — this is the policy line underneath it.

## 3. A state-dependent shot is one-shot

Re-running a capture after the lab has moved on silently overwrites a correct image with a
plausible-but-wrong one — no error, no warning, a valid file either way. That is exactly how the
M10 drift-diff capture was clobbered on 2026-07-26. Capture, verify the image immediately, and do
not re-run "to be safe" — re-running *is* the risk, not the safety net.

Related trap: two rows in the same module can be the **same URL at two different moments** (a
before/after pair — e.g. an alert Inactive, then the same alert Firing). Shoot them in the order
the manifest lists them; shooting the "after" first makes the "before" unrecoverable without a
full reset.

`capture.py` enforces this mechanically (`reshoot: false` by default — see
`tools/media/README.md` §"Writing jobs" rule 6); this rule is what to do when there is no
harness — a manual screenshot or a hand-driven recording has no clobber guard at all.

## 4. A capture that lands on the login page still "succeeds"

A headless run pointed at an authenticated page that isn't actually authenticated still writes a
valid, correctly-sized PNG — of the login screen. The run reports success, the file exists, the
size heuristic doesn't flag it (a login page isn't a tiny splash image), and nothing downstream
notices until a human opens the file.

**Rule:** any capture workflow must assert it is authenticated *before* shooting (session/cookie
check, or a wait on authenticated-only content), and the person reviewing must look at what the
image actually shows — "the run completed" and "the shot is correct" are different claims. This
is the same failure shape as the Showroom-cockpit splash screen documented in
`tools/media/README.md` ("Why a driver, and not just `chrome --screenshot`"): a valid file is not
proof of the right page.

## 5. Force light theme

All 42 images already in the tree are light-theme. A fresh browser profile — a new Chrome
profile, a new headed login window, a laptop with dark mode on — renders the OpenShift console in
dark by default. A batch of new captures made without forcing light theme will not match the
existing set, and nobody notices in a diff review because both are "a valid console screenshot."

**Rule:** force light theme for every new capture (console user preference, or the driver's
launch flags) and check one image against the existing set side by side before running a whole
job file. Cheaper to check once up front than to redo a batch after the mismatch is noticed in
review.

## 6. Console vocabulary can be verified without logging in

The OpenShift console serves its own translation bundles unauthenticated, at
`/static/locales/en/`. That is the cheapest way to check a nav label, a button string, or a menu
name before writing it into a page or a manifest row — no cluster login, no session, no capture
run required. Reach for it before spending a login window confirming wording that a JSON file
already answers, and before marking a `[CAPTURE-VERIFY]` marker as needing a full grounding pass
if it's really just a label lookup.

This does not replace a real capture where the *state* (not just the label) is the point — see
rule 4 and `tools/media/CONSOLE-GROUNDING.md` for the difference between "what does the button
say" and "what does the page look like right now."
