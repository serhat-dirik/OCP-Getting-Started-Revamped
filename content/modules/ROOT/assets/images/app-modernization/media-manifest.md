# M22 media manifest — Application Modernization (MTA + Developer Lightspeed)

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module's **marquee visuals are the MTA analysis report** (the *Issues* view showing the mandatory
blockers and the **24 story-point** effort total on `parasol-legacy-claims`) and the **Developer Lightspeed
for MTA diff** (the extension proposing `System.getenv("CLAIMS_DB_URL")` for the hardcoded-IP issue). No
static diagram conveys "MTA measured this app at 24 points and here are the six blockers," so the report and
the AI-diff screenshots are the priority of the media pass. All report **data**, effort numbers, and the AI
**output** were captured on-cluster (OCP 4.21.22, Kubernetes 1.34, MTA 8.1.2, model served by the workshop
MaaS endpoint, 2026-07-13) by driving the MTA Hub API and a real completion; the console **click-paths** and
the Dev Spaces extension UI are the deferred media pass and carry `[CAPTURE-VERIFY]` in the `.adoc`. Every
screenshot needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc` files with
a commented `// media-pass:` (diagrams) or `[CAPTURE-VERIFY]` (console/IDE) line — replace with the
`image::…` when the asset lands. **The two diagrams below are already rendered and committed**
(2026-07-26, label-space fix 2026-07-28) — only the screenshots and recording remain the pending
capture. **Do not shoot those yet** — this is the spec; capture in the media phase, and
scrub the cluster domain to a placeholder (`apps.example.com`) and the user to `{user}` in every frame.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `app-modernization-01-mta-flow.svg` | concept.adoc Mermaid "How MTA analysis works" — `examples/diagrams/app-modernization/01-mta-flow.mmd` | Git source + target chips (cloud-readiness/linux/openjdk/jakarta-ee/jws) feeding the analyzer addon in the shared Hub; report (issues + effort) to "you"; loop through a Dev Spaces + Developer Lightspeed `[ADS]` fix back to the source. The module's spine — reused on concept slide 3 |
| `app-modernization-02-modernize-loop.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/app-modernization/02-modernize-loop.mmd` | the linear loop legacy (24 pts) → MTA analysis (6 mandatory) → fix (Developer Lightspeed `[ADS]` / manual) → re-analyze (effort drops) → parasol-claims-modernized on OpenShift |

Shared legend: the Git-repo box, the migration-target chip, the analyzer/Hub box, the report card
(mandatory/optional/potential + effort badge), the Dev Spaces + Lightspeed fix chip — Red Hat-neutral
palette, no vendor-logo soup. Do **not** print the MTA / OCP version numbers on the diagrams (prose carries
the version via the attribute).

## Screenshots — the MTA report (MARQUEE) + the AI diff

16:10, default console theme, `{user}`=`user1`, numbered red-circle annotations matching step numbers.
For the multi-click console flows an **animated gif/mp4 (<30 s, silent) is PREFERRED** over static shots
(`04-STYLE-GUIDE §4`); this is a product-console-heavy module, so it warrants rich visual treatment.

| Filename | Lab step | Shows / what to notice |
|----------|----------|------------------------|
| `app-modernization-01-create-application.png` | Lab 2 | ✅ CAPTURED 2026-08-01 (cluster 2) as a **`.png`, not the specified `.gif`** — the whole point of the row is the filled form, and one still frame carries Name + Source Repository + Branch together. The **MTA console needs no sign-in on this cluster** (it opens straight on Application inventory), so no OAuth session was involved. Shows the *New application* drawer filled: Name `parasol-legacy-claims-user8`, expanded *Source code* section, *Repository type* `Git`, *Source Repository* the HTTPS Gitea fork URL, *Branch* `main`. `[CAPTURE-VERIFY]` labels resolved — the button is **Create new**, the drawer is **New application**, the field is **Source Repository**, the submit is **Create**, exactly as `lab.adoc`'s grounding comment already says |
| `app-modernization-02-set-targets.png` | Lab 2 | ✅ CAPTURED 2026-08-01, `.png` not `.gif`. The *Analyze → Set targets* wizard step. **Two spec corrections.** (a) This row named *"Containerization, OpenShift, OpenJDK"* — **there is no "OpenShift" tile**; the five tiles are the ones `lab.adoc` names (Containerization, Linux, OpenJDK, Jakarta EE 9, JBoss Web Server 6) and all five were selected for this run. (b) A tile is selected through the **checkbox in its top-right corner** — clicking the card body leaves it unselected while looking like it worked, which silently cost one wizard run. Also: the OpenJDK tile **defaulted to OpenJDK 21** on MTA 8.0.1, where `lab.adoc` warns the default is 11. Frame limitation: the modal viewport shows ~1.5 rows of the tile grid, so only *Containerization* is visible as selected; the other four are below the fold |
| `app-modernization-03-analysis-complete.png` | Lab 2 | ✅ CAPTURED 2026-08-01. The application row with *Analysis* = **Completed** (green check), plus its Tags and Effort totals. **No *Report* link exists on the row** in MTA 8.0.1 — the report is reached from the Issues views / the row's kebab, not a column link, so this row's wording was inaccurate. Measured runtime: the analyzer task finished well inside the "few minutes" `lab.adoc` states (not the ~90 s this row claimed) |
| `app-modernization-04-issues-report.png` | Lab 3 | ✅ CAPTURED 2026-08-01. **MARQUEE** — the *Issues* view with the issue name, Category, Source, Target(s), Effort and affected-application columns. **The numbers this row specifies did not reproduce and the difference is real, not a mistake:** this cluster runs **MTA 8.0.1**, the lab's figures were measured on **MTA 8.1.2**. The same five targets in Source-code mode produced **4 issues (3 mandatory + 1 potential)** and an application effort total of **13**, against this row's 6 mandatory / 24. `Hardcoded IP Address` and the `javax`→`jakarta` issue are both present; "Version of Spring not compatible with Jakarta EE 9" is not. `lab.adoc` now carries a NOTE telling attendees their numbers move with the MTA build and to read their own report. **The lab's own measured figures were left alone** — they are correctly attributed to a stated version and date, and re-grounding them is a research task, not a media one |
| `app-modernization-05-issue-incident.png` | Lab 3 | ✅ CAPTURED 2026-08-01. The *Hardcoded IP Address* issue drilled to its incident: dialog titled with the file path ending `src/main/resources/persistence.properties`, tab **"Incident #1: Line 7"**, the file contents with line 7 (`jdbc.url=jdbc:oracle:thin:@…`) underlined, and the rule hint. Click-path, since it is not obvious: *Issues → Single application → pick the application → the row's affected-files count (a **button**, not a link) → the file row*. **Privacy check:** the snippet includes the sample app's fake `jdbc.user`/`jdbc.password=claims`. That is deliberate teaching material — the identical lines are already in `lab.adoc:123` and in `apps/parasol-legacy-claims/src/main/resources/persistence.properties`, and the exercise exists to make attendees look at them. No real credential appears |
| `app-modernization-06-lightspeed-diff.png` | Lab 4 | ⬜ NOT CAPTURED 2026-08-01 — Dev Spaces is behind OpenShift OAuth **and** the shot needs a running IDE workspace with the MTA extension view open. This is the "separate products / needs a running DevWorkspace and an IDE" class the runbook already parks; not capturable by a URL-driven harness |
| `app-modernization-07-reanalysis-delta.png` | Lab 5 | ⬜ NOT CAPTURED 2026-08-01 — **depends on row 06.** The delta is only meaningful *after* the lab's own fix flow has been performed; synthesising the fix by pushing a commit to the fork would produce a real-looking number that no attendee path produces. Deliberately left for whoever can drive the Dev Spaces beat. (For that person: the "before" run is on disk in the shared MTA Hub as `parasol-legacy-claims-user8`, application id 1, effort 13 on MTA 8.0.1) |
| `app-modernization-08-topology-modernized.png` | Lab 6 | ⬜ NOT CAPTURED 2026-08-01 — **blocked on console authentication** (see the note below) |

### Capture note, 2026-08-01

**The MTA console required no login on this cluster** — it serves the Application inventory
anonymously (`createUser` on the created application reads `admin.noauth`), which is why rows 1–5
are done. That is worth knowing for future passes: the MTA rows are *not* in the same blocked class
as the OpenShift-console rows, despite this manifest previously grouping them together.

**Row 8 is blocked on an OAuth session, nothing else.** A console session needs a human to type a
password into the OpenShift login page (`tools/media/login.py` exists for that) and the operator of
this pass is barred from typing credentials. The cached `tools/media/shot-profile.session.json` is
valid for a different cluster; a headless probe of cluster 2's console returned **401**.

**Shared-Hub caution:** the MTA Hub is cluster-wide, not per-namespace, so `parasol-legacy-claims-user8`
is now sitting in the inventory of the shared Hub on cluster 2. `lab.adoc`'s reset note already says
to delete the application in the MTA console to re-run the "add app" beat cleanly; that is the
cleanup for this capture run too.

## Recording — terminal cast (demo-arc happy path)

| Filename | Notes |
|----------|-------|
| `app-modernization-demo.cast` | asciinema cast of the terminal-visible slice of the demo arc: the source-inspection (Lab 1), the `[ADS]` wiring check + the grounded MaaS `curl` returning the `System.getenv` completion (Lab 4 NOTE), and the deploy + probe break-and-fix (Lab 6 CLI tab). The MTA console + Dev Spaces beats are screen-capture (gif) since they're product UIs. Record in `{user}-modernize`; scrub the domain to `apps.example.com`; **never** show the MaaS key (the `curl` decodes it inline — re-record or redact so the Bearer value never appears on screen) |

## Narration

Narrated walkthrough script derives from the demo flavor (Say/Show/Do ≈ narration + shot list) during the
media phase. The three beats — *the report measures 24 points*, *Developer Lightspeed proposes the diff you
review*, *re-analysis proves the drop* — are the shot list.
