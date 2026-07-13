# M22 — Application Modernization (MTA + Developer Lightspeed)

## Slide: Don't lift-and-shift the WAR — measure it

- Parasol's original claims service: Java 8 Spring-on-Tomcat WAR
- DB address, password, audit-log PATH — all baked into the build
- Container filesystem is ephemeral + non-root; config belongs in a Secret
- Servlet-era runtime expects an app server that isn't there
- MTA reads the SOURCE and prices every blocker BEFORE you commit a sprint

Notes: Open on the temptation and why it fails. The easy move is to wrap the existing WAR in a container image and call it modernized. It fails for structural reasons, not cosmetic ones. The datasource URL — a hardcoded database IP — the username and password live in a properties file inside the WAR; on OpenShift that belongs in a ConfigMap and a Secret injected as environment variables so the same image runs in dev, test, and prod. The app writes an audit log to a hardcoded host path; containers run as a random non-root user on an ephemeral, read-only-by-default filesystem, so that write fails and the file would vanish on restart anyway — logs belong on stdout. And a WAR expects a servlet container to be there; the cloud-native shape is an embedded runtime where the app is the process. None of this is visible from the outside. The Migration Toolkit for Applications reads the source and tells you precisely which of these — and how much effort each — before you hit them in production.
Visual: Left panel "Lift-and-shift" — a WAR box being dropped into a container, with three red call-outs pinned to it: "hardcoded DB IP + password," "writes /opt/parasol/logs/... (can't)," "needs Tomcat (not here)." Right panel "MTA" — the same source feeding an analyzer that emits a tidy report card with a "24 story points · 6 mandatory" badge. Arrow between: "measure before you move."

## Slide: The 6 Rs — a decision, not a slogan

- Retain · Retire · Rehost · Replatform · Refactor · Repurchase
- Choose per app, honestly, on COST and VALUE — not fashion
- Rehost = lift-and-shift (buys time, pays no debt down)
- Replatform = externalize config + logs, containerize (most of this module)
- parasol-legacy-claims = replatform-leaning-refactor

Notes: Every legacy app gets one of six dispositions, and the skill is choosing honestly, per app, on cost and value. Retain: leave it where it is for now — a stable integration nobody touches this year. Retire: turn it off — a reporting app superseded by a dashboard. Rehost: lift-and-shift the same app to new infra with no code change, which buys time but pays no modernization debt down. Replatform: small changes to fit the platform — externalize config and logs, containerize — which is most of what this module does. Refactor: rework the code or architecture, break the monolith, adopt an embedded runtime. Repurchase: replace with SaaS. Our seeded app is a replatform-leaning-refactor candidate: the fixes MTA flags are exactly the replatform boundary, and the strangler pattern is how you'd take it the rest of the way without a big-bang rewrite.
Visual: A 2×3 grid of the six Rs, each a card with a one-line "when it's right" and a tiny Parasol example. The Replatform card is highlighted; a marker pin labeled "parasol-legacy-claims" sits on the Replatform↔Refactor boundary.

## Slide: How MTA analysis works

- Point MTA at the SOURCE; pick migration TARGETS (goals)
- Rule engine (39 rulesets live) reports every place the code trips a rule
- Each issue: a CATEGORY (mandatory / optional / potential) + an EFFORT score
- Targets for containerizing Java: cloud-readiness · linux · openjdk · jakarta-ee · jws
- Re-analysis after a fix shows the effort NUMBER DROP — measurable

Notes: MTA is a rule-based static analyzer. You point it at an application's source, select one or more migration targets, and it runs a large library of rules — the live Hub ships 39 rulesets — reporting every place your code trips a rule. Three ideas make the report usable. Targets are goals: you don't ask "is my code bad," you ask "what stops this from reaching this target." The targets for containerizing a legacy Java app are cloud-readiness and linux for OpenShift readiness, openjdk to move off older JDKs, jakarta-ee for the javax-to-jakarta namespace move, and jws for the Tomcat runtime rules. Issues have a category — mandatory, optional, or potential — and triage starts with mandatory. And effort is a number: each issue carries a relative story-point estimate, so "this feels hard" becomes "24 points," and a re-analysis after fixing shows the number drop.
Visual: The concept diagram m22-app-modernization-01-mta-flow.svg — the Git source + the target chips feeding the analyzer addon in the shared Hub, emitting a report (issues + effort) to "you," who loop through a Dev Spaces + Developer Lightspeed fix back to the source.

## Slide: Read the report like a consultant

- parasol-legacy-claims (live): 24 story points · 6 mandatory · 1 potential · 15 tech tags
- Mandatory: Spring/Jakarta EE 9 (eff 3) · Hardcoded IP · File-system write · javax→jakarta · Tomcat/JWS
- Start with MANDATORY; the tech tags are context, not work
- GROUP by fix: seven findings → ~three pieces of work
- The modern Quarkus counterpart scores 1 — that's the destination

Notes: A raw report is a wall of findings; your job is to turn it into a short work list. Here is what our seeded app actually reports, performed live: 24 story points across 6 mandatory issues, 1 potential, and 15 technology tags. The mandatory issues are the whole story in one screen — Spring not compatible with Jakarta EE 9 at effort 3, then a hardcoded IP, a filesystem write, the javax-to-jakarta package move, a javax.activation swap, and a Tomcat-not-compatible-with-JBoss-Web-Server finding at effort 1 each. The consultant's read: start with mandatory — those seven are the whole job, the technology tags are context. Group by fix, not by finding — three of the mandatory issues are one migration, the javax-to-jakarta move; the hardcoded IP and the filesystem write are the externalize-config theme; grouped, seven issues become three pieces of work. And effort is relative — the Spring/Jakarta issue is the heaviest, the config externalizations are the cheap high-value wins you do first. For contrast, Parasol's fully modernized Quarkus claims service scores 1 — that gap is what modernization earns.
Visual: A stylized report table — the seven issues with category chips (red=mandatory, amber=potential) and effort badges, three of them lassoed and labeled "one migration: javax→jakarta," two lassoed "externalize config." A side gauge shows "24 → (fix) → … → 1 (modern)."

## Slide: AI proposes, the engineer disposes

- Developer Lightspeed for MTA = an AI feature of the MTA VS Code / Dev Spaces extension [ADS]
- Give it one issue → it returns a concrete DIFF (model-agnostic; MaaS-backed here)
- Real output: hardcoded jdbc URL → dataSource.setUrl(System.getenv("CLAIMS_DB_URL"))
- What it does NOT do: migrate for you, guarantee correctness, know your business rules
- READ every diff like a junior wrote it under pressure — then re-analyze to PROVE it

Notes: Reading the report tells you what to fix; Developer Lightspeed for MTA helps you do it in the IDE. First disambiguate — there are three Lightspeeds: OpenShift Lightspeed is the console assistant, Developer Lightspeed for Red Hat Developer Hub answers questions in the portal, and Developer Lightspeed for MTA is a feature of the MTA extension that, given a specific analysis issue, calls a language model and proposes a concrete code change. It's genuinely useful and genuinely bounded. What it does: takes one issue, the surrounding code, and the target, and returns a diff — for our hardcoded-IP issue it rewrote the compiled-in URL into a System.getenv lookup, which is exactly right. What it does not do: migrate your app for you, guarantee a compilable or correct result, or understand your business rules. The output is a suggestion from a probabilistic model — sometimes perfect, occasionally confidently wrong. The one rule that makes this safe: read every diff as if a junior engineer wrote it under time pressure, and re-analyze to prove the issue is gone. AI compresses the typing, not the accountability. This is an [ADS] feature; where it's absent the lab degrades to a manual fix of the same issue.
Visual: A split card. Left: the MTA extension showing the "Hardcoded IP" issue and a proposed diff (red literal URL struck through, green System.getenv line added), an "Accept" button, and a magnifier over the diff labeled "read it first." Right: a caution strip "AI proposes · engineer disposes" and a small "[ADS] · degrades to manual" tag.

## Slide: Modernization is a funnel, not a big bang

- Assess the portfolio → Analyze candidates → Fix high-value/low-effort → Retain/retire the rest
- Ship early cheap wins; bank the pattern and the credibility
- Big monolith? STRANGLER pattern: run the modern service BESIDE the legacy, move traffic slice by slice
- Coexistence is a CONNECTIVITY problem → Service Interconnect (module M21)
- When NOT to: retire-worthy apps, replatform-is-enough, un-reviewable AI diffs

Notes: You do not modernize a portfolio by rewriting all of it at once — you run a funnel. Assess the whole portfolio with a questionnaire per app to rank candidates; analyze the candidates with MTA to price them; fix and ship the ones where effort is low and value is high, banking the win and the pattern; repeat, and retain or retire the rest deliberately. The incremental path for a big monolith is the strangler pattern: stand the modern service up beside the legacy one, route a slice of traffic to it, and grow that slice until the legacy app is strangled — off, with no big-bang cutover. That routing and coexistence is a connectivity problem, exactly what Service Interconnect solves across clusters and sites, which is module M21. And be honest about when not to modernize: retire what you'll turn off within the year, stop at replatform when it gets you most of the value, and never accept an AI diff you didn't read.
Visual: A funnel graphic — wide "portfolio (assess)" at top narrowing through "analyze (MTA effort)" to "fix + ship" at the spout, with a small "retain/retire" side-chute. Below the funnel, a strangler mini-diagram: legacy box and modern box side by side, a traffic-split dial moving from 100/0 toward 0/100, labeled "Service Interconnect → M21." A footer "When NOT to: retire · replatform-enough · un-reviewed AI."
