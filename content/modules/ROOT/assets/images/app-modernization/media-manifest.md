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
`image::…` when the asset lands. **Do not shoot yet** — this is the spec; capture in the media phase, and
scrub the cluster domain to a placeholder (`apps.example.com`) and the user to `{user}` in every frame.

## Diagrams (SVG exports of the inline Mermaid, committed next to the source)

| Filename | Source | Notes |
|----------|--------|-------|
| `app-modernization-01-mta-flow.svg` | concept.adoc Mermaid "How MTA analysis works" | Git source + target chips (cloud-readiness/linux/openjdk/jakarta-ee/jws) feeding the analyzer addon in the shared Hub; report (issues + effort) to "you"; loop through a Dev Spaces + Developer Lightspeed `[ADS]` fix back to the source. The module's spine — reused on concept slide 3 |
| `app-modernization-02-modernize-loop.svg` | wrapup.adoc Mermaid recap | the linear loop legacy (24 pts) → MTA analysis (6 mandatory) → fix (Developer Lightspeed `[ADS]` / manual) → re-analyze (effort drops) → parasol-claims-modernized on OpenShift |

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
| `app-modernization-01-create-application.gif` | Lab 2 | MTA console *Application inventory → Create new application*: name + the HTTPS Gitea repo URL + branch `main`. Notice the *Source code* repository field. `[CAPTURE-VERIFY]` labels |
| `app-modernization-02-set-targets.gif` | Lab 2 | The *Analyze → Set targets* wizard step with *Containerization*, *OpenShift*, *OpenJDK* selected. Notice these friendly names map to rule labels `cloud-readiness`/`linux`/`openjdk`/`jakarta-ee`/`jws` |
| `app-modernization-03-analysis-complete.png` | Lab 2 | The application row at *Completed* with a *Report* link. Notice the ~90 s task finished |
| `app-modernization-04-issues-report.png` | Lab 3 | **MARQUEE** — the *Issues* view: the six mandatory blockers sorted by category/effort and the **24** effort total. Notice "Version of Spring not compatible with Jakarta EE 9" (effort 3) and "Hardcoded IP address" |
| `app-modernization-05-issue-incident.png` | Lab 3 | Drilling into the *Hardcoded IP address* issue → the incident pointing at `persistence.properties`. Notice the file:line and the rule hint |
| `app-modernization-06-lightspeed-diff.png` | Lab 4 | **MARQUEE** — the Dev Spaces MTA extension proposing the diff: the literal `jdbc:oracle:thin:@...` struck through, `System.getenv("CLAIMS_DB_URL")` added, with the *Accept* action. Notice "read the diff before accepting" |
| `app-modernization-07-reanalysis-delta.png` | Lab 5 | The re-analysis report with the *Hardcoded IP* issue resolved and an effort total **below 24**; ideally side-by-side with the modern Quarkus app's report (effort **1**). Notice the drop |
| `app-modernization-08-topology-modernized.png` | Lab 6 | OpenShift *Topology* for `{user}-modernize` showing `parasol-claims-modernized` — first *not ready* (wrong `/health` probe), then *Ready* after the `/q/health/ready` fix. Notice the probe break-and-fix |

## Recording — terminal cast (demo-arc happy path)

| Filename | Notes |
|----------|-------|
| `app-modernization-demo.cast` | asciinema cast of the terminal-visible slice of the demo arc: the source-inspection (Lab 1), the `[ADS]` wiring check + the grounded MaaS `curl` returning the `System.getenv` completion (Lab 4 NOTE), and the deploy + probe break-and-fix (Lab 6 CLI tab). The MTA console + Dev Spaces beats are screen-capture (gif) since they're product UIs. Record in `{user}-modernize`; scrub the domain to `apps.example.com`; **never** show the MaaS key (the `curl` decodes it inline — re-record or redact so the Bearer value never appears on screen) |

## Narration

Narrated walkthrough script derives from the demo flavor (Say/Show/Do ≈ narration + shot list) during the
media phase. The three beats — *the report measures 24 points*, *Developer Lightspeed proposes the diff you
review*, *re-analysis proves the drop* — are the shot list.
