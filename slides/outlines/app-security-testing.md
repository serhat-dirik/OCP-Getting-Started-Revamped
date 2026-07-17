# M27 — Application Security Testing (SAST · SCA · DAST)

## Slide: A green build is not a safe build

- `parasol-claims` compiles, its tests pass, it deploys — and it is still insecure
- A hard-coded password is valid Java: green build, green tests, secret in every image
- A five-year-old dependency with a deserialization RCE runs fine — until it is attacked
- A privileged root container with SYS_ADMIN and no limits starts up happily
- A header-less app serves its JSON correctly — and lets a browser MIME-sniff, frame, and leak it
- None of these is a "bug" — it is SECURITY DEBT a compiler and a unit test cannot see

Notes: Open on the trap. A traditional pipeline answers one question — does it compile and do the tests pass — and that says nothing about security, because the most dangerous defects are invisible to a compiler and a unit test. Walk the four that ship inside a green build. A hard-coded password compiles perfectly; a private final String literal is valid Java, so the build is green and the secret is now in every copy of the image, readable by anyone who unpacks the jar. A vulnerable dependency does exactly what your code asks of it — a library with a deserialization remote-code-execution hole runs fine until an attacker sends the payload that triggers it. An insecure container starts up happily — privileged, as root, with SYS_ADMIN and no resource limits — it just also hands the node to anyone who lands inside it. And a missing security header is silent — the app serves its JSON correctly, it simply never told the browser not to sniff, frame, or leak it. None of these fails in the "it doesn't work" sense; they are security debt, and the only way to stop them shipping is to test for them explicitly and fail the build when they appear. That is exactly what this module builds.
Visual: A single green CI check labelled "build ✓ · tests ✓" — and behind it, four peeled-back layers exposing the hidden flaws: a hard-coded password string, a cracked dependency jar tagged "RCE", a privileged root container, and a browser reading a header-less response. Caption strip: "green says nothing about safe."

## Slide: The five pillars, mapped to pipeline stages

- SAST — a flaw in the SOURCE we wrote (a secret, an injection)? → SonarQube quality gate
- SCA — a known vulnerability in a DEPENDENCY we pulled in? → Trivy filesystem scan
- Image risk — a known vulnerability in the BUILT IMAGE's layers? → RHACS image scan
- Config security — an insecure DEPLOYMENT about to apply? → RHACS `roxctl deployment check`
- DAST — the RUNNING app misbehaving (missing headers)? → ZAP (Zed Attack Proxy, formerly OWASP ZAP) baseline scan
- Five questions, each answered at a DIFFERENT point in the software's life

Notes: Five pillars, and the discipline is knowing which class of bug each one catches that the others miss. SAST — static application security testing — reads the source you wrote and finds the hard-coded secret or the injection; here that is a SonarQube quality gate, run before build. SCA — software composition analysis — checks the dependencies you pulled in for known vulnerabilities; here Trivy scans the source tree, also before build. Image risk asks whether the built image, base layers and all, carries a known vulnerability; RHACS scans the image, after build. Config security asks whether the Deployment you are about to apply is insecure — privileged, no limits, excess capabilities; RHACS roxctl deployment check reads the manifest, before deploy. And DAST — dynamic application security testing — exercises the running app for things you can only see once it answers a request, like missing headers; ZAP, the Zed Attack Proxy, runs a baseline scan after deploy. The shape of the pipeline is the lesson: security is not a stage at the end, it is a property checked at every stage.
Visual: The concept diagram m27-app-security-testing-01-five-pillars.svg — source → SAST → SCA → build → image scan → config check → deploy → DAST, with the five gates coloured by family (shift-left blue, shift-right amber) and the plain build/deploy steps in grey. Reused on concept slide 3.

## Slide: Shift-left vs shift-right — catch it where it's cheapest

- The five pillars split into two families, and the split is about COST
- Shift-LEFT (SAST, SCA, config): run on the SOURCE and MANIFESTS, before build or deploy
- Shift-RIGHT (image scan, DAST): run on the BUILT IMAGE and RUNNING app, after deploy
- A secret caught in code review is a one-line fix; the same secret in production is an incident
- Some flaws ONLY exist once assembled — a base-layer CVE, a header that needs a live response
- Neither family replaces the other — a mature pipeline runs BOTH

Notes: The pillars fall into two families and the split matters for cost. Shift-left — SAST, SCA, and the config check — runs against the source and the manifests, before you build or deploy. That is the cheapest place to catch a flaw: no image to rebuild, no environment to stand up. A hard-coded secret found by static analysis is a one-line fix in a code review; the same secret found in production is an incident. Shift-right — the image scan and DAST — runs against the built image and the running app, and some things can only be seen there: a vulnerability in a base-image layer you did not write, or a response header that only exists once the server actually answers a request. Neither family replaces the other. Shift-left catches problems early and cheap; shift-right catches problems that only exist once the software is assembled and running. Say it plainly: a mature pipeline does both.
Visual: The same m27-app-security-testing-01-five-pillars.svg, read this time as two bands — the blue shift-LEFT gates sitting before the "build" step, the amber shift-RIGHT gates after it — with a cost arrow underneath rising from "cheap one-line fix" on the left to "production incident" on the right.

## Slide: Defense in depth — the log4shell beat

- The most important idea: check the SAME class of risk at MORE THAN ONE layer
- log4shell (CVE-2021-44228), the critical Log4j RCE, makes it concrete
- In the lab it is baked into the IMAGE at build time — NOT declared in `pom.xml`
- The source SCA scan (Trivy, shift-left) is CLEAN — there is nothing in the tree to find
- The image scan (RHACS, shift-right) catches it anyway — it inspects the ASSEMBLED image, layer by layer
- Remove either gate and the vulnerable image ships — WHERE you scan decides WHAT you catch

Notes: This is the marquee idea. Defense in depth means no single scanner sees everything, so you check the same class of risk at more than one layer, and a miss in one is caught by the next. The lab makes it concrete with log4shell — CVE-2021-44228, the critical Log4j remote-code-execution flaw. Here is the trick: if log4shell had entered as a declared dependency in pom.xml, the SCA scan — Trivy, shift-left — would have caught it in the source. But in the lab it is baked directly into the image at build time, never declared in pom.xml at all. A source scan cannot see it; there is nothing in the tree to find. The image scan — RHACS, shift-right — catches it anyway, because it inspects the assembled image, layer by layer. That is defense in depth in one screen: a dependency that slips past the source scanner is stopped by the image scanner. Remove either gate and the vulnerable image ships. This is why "we run a dependency scanner" is not the same as "we scan for vulnerabilities" — where you scan decides what you can catch.
Visual: A two-track panel for the same log4shell jar. TOP track "source scan (Trivy)" reads `pom.xml`, finds nothing, stamped green "CLEAN — not declared here." BOTTOM track "image scan (RHACS)" reads the assembled image layers, finds `log4j-core` inside a layer, stamped red "CVE-2021-44228 CRITICAL." A brace joining them labelled "defense in depth — the second layer catches what the first can't see."

## Slide: Policy-as-a-gate — a scanner that can't fail the build is theater

- A scan that only writes a report nobody reads changes NOTHING
- A gate is a scan that can STOP the line: a red result fails the build
- SonarQube: the quality gate goes ERROR when the vulnerability count is greater than zero
- Trivy · `roxctl` · ZAP: a non-zero exit fails the TaskRun and halts the PipelineRun
- The M27 capstone runs all five as GATES — one red gate stops everything downstream
- Honest edge: if you can't triage a gate's findings yet, start it REPORT-ONLY, not off

Notes: A scanner is only real if it fails the build. A scan that just writes a report becomes a report nobody reads, and it changes nothing. The whole move in this module is turning each scan into a gate — something that can stop the line. Concretely: SonarQube's quality gate goes to ERROR when the vulnerability count is greater than zero, and the pipeline waits on that result; Trivy, roxctl, and ZAP each exit non-zero when they find something over threshold, which fails the TaskRun and halts the PipelineRun. The M27 capstone wires all five in as gates, so a red result at any layer stops everything downstream — that is the difference between security theater and a security control. One honesty note, which the wrap-up returns to: a gate you cannot keep triaged trains your team that red means "click through", which is worse than no gate. If you cannot stay on top of a gate's findings yet, start it in report-only mode and promote it to a build breaker when you can — do not turn it off, and do not turn it on and ignore it.
Visual: A scan result hitting a fork. One path "report only" → a document dropped onto a pile of unread reports, greyed out. The other path "gate" → a red barrier across the pipeline with the PipelineRun halted behind it and a "non-zero exit" chip. Caption: "a gate is a scan with consequences."

## Slide: Where does each finding actually live?

- The common complaint isn't "it finds nothing" — it is findings SCATTERED and unreadable
- A pipeline that only says "stage failed" teaches nobody — route each gate to a console you READ
- SAST → the SonarQube DASHBOARD: the failing condition, the exact rule (S2068), the file and line
- SCA → the TaskRun LOGS plus a CycloneDX SBOM artifact of every dependency
- Image + config → the RHACS console VIOLATIONS / a TaskRun JUnit report; DAST → the ZAP WARN/FAIL summary + HTML report
- The whole run → the OpenShift Pipelines GRAPH (which stage is red) + Tekton Results (history)

Notes: The most common complaint about security tooling is not that it fails to find things — it is that the findings are scattered and unreadable, and a red pipeline that only says "stage failed" teaches nobody. This is the direct answer to "our security reporting is weak", and the module drills it as a hands-on skill: read each finding in its native console. SAST lands in the SonarQube dashboard for your project — the failing quality-gate condition, the exact rule like S2068 for a hard-coded credential, the file and the line. SCA lands in the TaskRun logs, with a CycloneDX software-bill-of-materials artifact listing every dependency in the build. The image scan lands in the RHACS console Violations — the policy that fired, the CVE, the image. The config check lands in the TaskRun logs as a JUnit report of the violated deploy policies. DAST lands as the ZAP WARN/FAIL summary plus an HTML report of every alert. And the whole run is the OpenShift Pipelines graph — which stage is red — with Tekton Results holding the historical runs and their logs. Reading a finding where it lives, not just "the pipeline is red", is what turns a gate from an obstacle into a tool.
Visual: A five-spoke hub — the red PipelineRun graph in the centre, arrows out to five labelled console cards: "SonarQube dashboard (S2068, file:line)", "Trivy TaskRun log + SBOM", "RHACS Violations (CVE + image)", "roxctl JUnit report", "ZAP WARN/FAIL + HTML report" — and a sixth card "Tekton Results: the red-then-green history."

## Slide: Supply-chain hygiene — trust, but pin

- Security tools are software too — and software gets COMPROMISED
- In March 2026 the Trivy GitHub Action was compromised; its signing keys were rotated after
- The lesson is not "don't use Trivy" (it is excellent) — it is HOW you consume it
- Pin by DIGEST, not by tag — a moved `:latest` can't silently change what runs in your build
- Prefer the CONTAINER image to the convenience GitHub Action — one fewer moving part
- Your scanners are part of YOUR supply chain — hold them to the same rigour as app dependencies

Notes: Security tools are software too, and software gets compromised. In March 2026 the Trivy GitHub Action was compromised, and the following month its package-signing keys were rotated after the incident. The lesson is not "don't use Trivy" — Trivy is excellent — it is how you consume it. Two habits. Pin by digest, not by tag: every scanner image in this pipeline is pinned to an immutable sha256 digest, so a compromised or moved latest tag cannot silently change what runs in your build. And prefer the container to the convenience wrapper: this pipeline runs the Trivy container image directly rather than the GitHub Action, which is one fewer moving part in the supply chain and exactly what the 2026 incident argues for. The framing that makes it stick: your security gates are part of your supply chain, so you treat them with the same rigour you apply to your own app dependencies. The wrap-up turns this into an org question — where are you floating on a moving tag today?
Visual: Two rows for the same scanner. TOP "float" — `trivy:latest` with a tag that quietly repoints to a compromised build (red), pulled through a GitHub Action wrapper. BOTTOM "pin" — `trivy@sha256:…` locked to an immutable digest (green), run as a plain container. A small timeline chip in the corner: "Mar 2026 — Trivy Action compromised."

## Slide: The red-to-green gauntlet — five gates, five fixes, one green run

- The demo arc: ONE seeded branch, five real flaws, every gate starts RED
- SAST red → externalize the hard-coded secret (M04's pattern) → green, and the next gate fires
- SCA red → drop the vulnerable `commons-collections` dependency → green
- Image red → stop baking log4shell into the image → green (defense in depth, live)
- Config red → restore the hardened Deployment manifest → green, the app deploys and gets its Route
- DAST red → add the HTTP security headers → EVERY gate green, the Route opens in the browser

Notes: This is the demo, and it is a gauntlet: one seeded branch with five real regressions, every gate red, and you drive it from red to green one fix at a time — each fix a real commit. SAST stops first — SonarQube found a hard-coded password — so you externalize it to configuration, exactly the pattern M04 teaches, and the gate goes green, which advances the run to the next gate. SCA fires next — Trivy found a critical remote-code-execution hole in a five-year-old commons-collections you pulled in — so you drop the dependency. Then the most important beat: the image scan fails on log4shell, which was never in your dependencies — it was baked into the image, and RHACS caught it because it scans the assembled image. You stop baking it in. The config gate fires — the Deployment ran privileged, as root, with SYS_ADMIN and no limits — so you restore the hardened manifest, and this time the run deploys the app and creates its Route for you. Last gate: DAST — ZAP found the running app never sets its security headers — so you add them in Quarkus config, commit, and re-run one final time. Every gate green, the image scanned and signed and deployed, and the Route opens in the browser. Green now means safe, because you made it mean that. Presenter tip: pre-run one red graph the day before — the build is long and you do not want to narrate a progress bar; the money moment is the whole graph going green.
Visual: The wrap-up diagram m27-app-security-testing-02-red-to-green.svg — the `seed-appsec` branch ("five flaws · every gate RED") flowing left to right through five fix steps ("externalize secret" · "drop vuln dep" · "stop baking log4shell" · "harden manifest" · "add headers") into a single green end state "every gate GREEN · scanned · signed · deployed."

## Slide: What's included, what's third-party [OCP]

- [OCP]: the capstone runs on the INCLUDED OpenShift Pipelines and Red Hat Advanced Cluster Security
- The three SCANNERS are third-party open source — called out plainly so you know what you adopt
- SonarQube Community Build — SAST, quality gates, the dashboard (no pull-request analysis)
- Trivy — SCA, license inspection, and the CycloneDX SBOM (open source, from Aqua Security)
- ZAP — the baseline DAST scan (open source)
- The TECHNIQUE transfers — five gates, defense in depth, findings you can read; swap scanners freely

Notes: This module runs on OpenShift Pipelines and Red Hat Advanced Cluster Security, both included with OpenShift, so it is tagged OCP. The three scanners it drives are third-party open source, and we call that out plainly so you know exactly what you are adopting. SonarQube Community Build is the free edition of SonarQube for static analysis — it gives you quality gates and the dashboard, but it has no pull-request analysis, so this pipeline analyzes the pushed revision and gates on that result. Trivy is an open-source scanner from Aqua Security for software composition analysis and license inspection, and it emits the CycloneDX bill of materials. ZAP is the open-source dynamic-analysis tool that runs the baseline scan. Here is the point to land: the technique is the transferable skill — five gates, defense in depth, findings you can read in their own console — and the specific scanners are swappable for whatever your organization has standardized on. You are not learning three products; you are learning a shape.
Visual: A two-column "what you adopt" card. LEFT "[OCP] — included" with the OpenShift Pipelines and RHACS marks. RIGHT "third-party open source" listing SonarQube Community Build, Trivy, and ZAP. Footer ribbon: "the technique is the skill; the scanners are swappable." No version numbers on the card (course standard).
