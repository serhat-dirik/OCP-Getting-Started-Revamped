# M27 media manifest — Application Security Testing (SAST · SCA · DAST)

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module's **marquee visual is the pipeline graph going from RED to GREEN** — the OpenShift Pipelines
console graph with a security gate red (the build stopped), paired with the same graph all-green after the
five fixes — because that pair carries the whole thesis: a green *build* said nothing about security until
the gates made it say so. The second marquee is the **log4shell defense-in-depth contrast** (the Trivy
*source* scan clean of it, the RHACS *image* scan catching CVE-2021-44228), the module's key beat. Every
pipeline run, finding, CVE and console view was captured on-cluster by driving the live
`parasol-claims-devsecops` capstone through its red-to-green gauntlet on 2026-07-15; the console button
labels (Pipelines *Start* / *Rerun*, the SonarQube dashboard, the RHACS *Violations* view) are the deferred
media pass and carry `[CAPTURE-VERIFY]` / `// CAPTURE-PENDING` in the `.adoc`. Every screenshot needs alt
text (what it shows + what to notice). Embed points are marked in the `.adoc` files with a commented
`// media-pass:` (diagrams) or `[CAPTURE-VERIFY]` / `// CAPTURE-PENDING` (console) line — replace with the
`image::…` when the asset lands. Capture **through the password-free authenticated attendee cockpit**
(project convention — never the raw console OAuth login). **The two diagrams below are already rendered
and committed** (2026-07-26, label-space fix 2026-07-28) — only the screenshots and recording remain the
pending capture. **Do not shoot those yet** — this is the spec; capture
in the media phase, and scrub the live cluster domain to a placeholder (`apps.example.com`) and the user to
`{user}` in every frame. **Never show a credential or token** — the Gitea push login, the SonarQube token,
and the RHACS API token must not appear in any terminal frame or pod-log capture.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `app-security-testing-01-five-pillars.svg` | concept.adoc Mermaid "The five pillars, mapped to pipeline stages" — `examples/diagrams/app-security-testing/01-five-pillars.mmd` | The pillars-to-stages map: source → SAST → SCA → build → image scan → config check → deploy → DAST, with the shift-LEFT gates (SAST · SCA · config, blue) before build and the shift-RIGHT gates (image · DAST, amber) after. Reused on concept slides 2 and 3 |
| `app-security-testing-02-red-to-green.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/app-security-testing/02-red-to-green.mmd` | The gauntlet: the `seed-appsec` branch (five flaws, every gate RED) flowing through five fix steps (externalize secret · drop vuln dep · stop baking log4shell · harden manifest · add headers) into one green end state (every gate GREEN · scanned · signed · deployed). Reused on the demo-arc slide |

Shared legend: the shift-LEFT gate box (blue), the shift-RIGHT gate box (amber), the plain build/deploy
step (grey), the RED failed-gate state, and the GREEN passed end state — Red Hat-neutral palette, no
vendor-logo soup. Do **not** print product version numbers on the diagrams (course standard — plain names
only).

## Screenshots — the red-to-green gauntlet + each finding in its console

16:10, default console theme, `{user}`=`user1`, numbered red-circle annotations matching the lab step
numbers. For the multi-click console flows an **animated gif/mp4 (<30 s, silent) is PREFERRED** over static
shots (`04-STYLE-GUIDE §4`).

| Filename | Lab step | Shows / what to notice |
|----------|----------|------------------------|
| `app-security-testing-01-pipeline-red-run.png` | Lab 1 | **MARQUEE** — the OpenShift *Pipelines* console graph for `parasol-claims-devsecops` on `seed-appsec`: `fetch-source` green, `sast-sonar` *red*, the run stopped. Notice a green *build* is a red *security* posture. `[CAPTURE-VERIFY]` graph node labels |
| `app-security-testing-02-pipeline-green-run.png` | Lab 6-7 | **MARQUEE (pair with 01)** — the same graph after the five fixes: every stage green (`sast-sonar` · `sca-trivy` · test · build · `image-scan` · sign · `deployment-check` · deploy · `dast-zap`). Notice green now means *safe* |
| `app-security-testing-03-sonarqube-quality-gate.png` | Lab 2 | The *SonarQube dashboard* for `parasol-claims-{user}`: quality gate *Failed*, condition *Vulnerabilities is greater than 0*, and the *S2068 — Credentials should not be hard-coded* issue on `PartnerGateway.java`. Notice the exact rule, file and line. **Read the two notes below before shooting this row** — one about the cluster state it needs, one about a string in the frame that must NOT be redacted. `[CAPTURE-VERIFY]` dashboard labels |
| `app-security-testing-04-rhacs-log4shell-violation.png` | Lab 4 | The *RHACS console* → *Violations*: the `parasol-claims` image violation for the *Block Log4Shell (CVE-2021-44228)* policy, severity *Critical*, showing the CVE, the `log4j-core` component, and the image digest. Notice the image scan caught what the clean Trivy *source* scan could not — defense in depth. `[CAPTURE-VERIFY]` Violations column labels |
| `app-security-testing-05-roxctl-deployment-check.png` | Lab 5 | The `deployment-check` *TaskRun log*: the `roxctl deployment check` violations on the insecure manifest (Privileged Container, CAP_SYS_ADMIN added, privilege escalation allowed, no CPU request / memory limit) with the MEDIUM+ total. Notice "you ship your configuration, not just your code" |
| `app-security-testing-06-zap-baseline-summary.png` | Lab 6 | The `dast-zap` *TaskRun* ZAP baseline WARN/FAIL summary against the running Route: the missing security headers (Content-Security-Policy, X-Content-Type-Options, anti-clickjacking). Notice DAST only sees this once the app is deployed and answering requests |
| `app-security-testing-07-route-security-headers.png` | Lab 6-7 | The deployed `parasol-claims` *Route* open in the browser with the dev-tools *Network → Headers* panel (or the `curl -sI` output alongside) showing the security headers now present. Notice the same header ZAP flagged is now set — the DAST gate is green |

### Screenshot 3 (SonarQube) — reachable surface, wrong state (assessed 2026-08-01)

**SonarQube needs no login for this.** Anonymous read is on: `/api/issues/search`,
`/api/components/search?qualifiers=TRK`, `/api/measures/component`,
`/api/qualitygates/project_status` and `/api/project_analyses/search` all answer **200** with no
credential. (`/api/projects/search` is the exception — it is admin-only and returns "Insufficient
privileges"; use `components/search` instead. Do not read that one 403 as "SonarQube is locked".)

**What blocks the row is the DATA, not the door.** On the capture cluster the only analysed project had
already been driven to the module's **green end state**, so:

* `alert_status` = `OK`, `vulnerabilities` = `0`, `security_rating` = `1.0`;
* the S2068 issue exists but is `status: CLOSED, resolution: FIXED` — `resolved=false` returns **0**;
* the gate-event history shows the red state *did* exist and was overwritten:
  `Failed` (15:46) → `Passed` (15:51) → `Failed` (20:16) → `Passed` (20:39).

The row needs the **RED** state. Shooting now yields a valid PNG of a passing project — a picture of the
opposite of the lesson. **Re-run the SAST stage against the seeded branch first**, confirm
`/api/issues/search?rules=java:S2068&resolved=false` returns 1, then shoot
`/project/issues?id=parasol-claims-<user>&open=<issueKey>&types=VULNERABILITY`. Wait on `S2068` **and**
`PartnerGateway.java` — never on "SonarQube", which is on every page including an empty one.

Two useful anonymous one-liners for confirming the state before you shoot:

```sh
curl -sk "$SQ/api/issues/search?rules=java:S2068&resolved=false&ps=5"     # must report total >= 1
curl -sk "$SQ/api/measures/component?component=parasol-claims-<user>&metricKeys=alert_status,vulnerabilities"
```

### ⚠️ PRIVACY — this row is the exception, and reversing it ruins the shot

The SonarQube issue detail renders the offending source line **verbatim**:

```
partnerApiPassword = "P@rasol-Partner-2026!"
```

**Do NOT blur, crop or redact it.** It is a **fabricated seeded flaw**, planted in `PartnerGateway.java`
on the `seed-appsec` branch precisely so a scanner can find it; it is already printed in plaintext in
this module's own lab page as expected output; and it *is the finding the screenshot exists to show*. A
redacted frame would show a security tool having found something the reader cannot see.

This is recorded here so a future reviewer does not (a) flag the committed image as a credential leak, or
(b) — far worse — generalise from it that "credentials in screenshots are acceptable." **They are not.**
The exception is exactly this one string, on the strength of it being fake, published, and load-bearing.
Everything else in this manifest's preamble stands unchanged: no real token, key, password or personal
email may appear in any frame, and every image is inspected by eye before it is committed. In particular
the Gitea push login, the SonarQube token and the RHACS API token remain forbidden in every capture.

## Recording — screen capture (demo-arc red-to-green gauntlet)

| Filename | Notes |
|----------|-------|
| `app-security-testing-demo.mp4` | Silent screen capture (<30 s per beat) of the demo arc: the Pipelines console graph stopping red at each gate in turn, the finding opened in its native console (SonarQube gate ERROR → RHACS log4shell Violation → roxctl TaskRun log → ZAP WARN summary), each real fix commit, and the money moment — the whole graph going green and the app's Route opening in the browser. Record in `{user}-cicd`; scrub the domain to `apps.example.com`; **never** run or show a command that prints the Gitea password, the SonarQube token, or the RHACS API token |

## Narration

Narrated walkthrough script derives from the demo flavor (Say/Show/Do ≈ narration + shot list) during the
media phase. The three beats — *a green build hides five flaws*, *each gate fails the build and you read the
finding where it lives*, *defense in depth catches the log4shell in the image that the source scan missed* —
are the shot list, closing on the whole graph going green and the Route serving its headers.
