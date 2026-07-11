# SA Provisioning Guide — enablement paths & module selection

Audience: the Red Hat SA (or instructor) **provisioning and planning** a session.
Attendees never see this page — their Showroom shows only the module library and the
modules you selected. (project direction 2026-07-11: recommended paths live here, not
on the attendee index; demo paths belong to the SA-Demos showroom, not the workshop.)

## How paths relate to module numbers

Module numbers follow the **teaching arc** (blocks A — Foundations → B — Delivery &
Trust → C — Platform → electives). A path is a **curated subset** for a time-box —
skipping numbers is expected and fine. Within any path, modules always run in
**ascending order**; a path that violates that is a defect. Roughly **four hands-on
modules make a day**.

## Workshop paths

| Path | Audience | Sequence |
|---|---|---|
| `WS-FULL-3D` (flagship) | 3-day full enablement | **Day 1** M01 → M02 → M03 → M04 · **Day 2** M07 → M08 → M09 → M10 · **Day 3** M11 → M12 → M14 → M23 |
| `WS-FULL-2D` | 2-day compressed | **Day 1** M01 → M02 → M03 → M04 · **Day 2** M07 → M09 → M10 → M12 |
| `WS-DEV-1D` | 1-day developer | M01 → M02 → M03 → M04 |
| `WS-OPS-1D` | 1-day devops / platform | M07 → M08 → M10 → M14 |

Composition rationale (change deliberately, not accidentally):

- **WS-FULL-3D** — Day 1 foundations core; Day 2 the delivery story in its natural
  order (build pipelines → trust the supply chain → GitOps → GitOps at scale): M08
  sits **beside M07** because the supply-chain gates extend the very pipeline the
  attendee just built. Day 3 broadens to developer experience (M11), operations
  (M12), multi-tenancy (M14), and the AI elective finale (M23).
  *(Fixed 2026-07-11: the earlier draft ran M12 before M08 on Day 3 — an
  ascending-order violation that made the numbering look wrong. The numbering was
  right; the path wasn't.)*
- **WS-FULL-2D** — drops trust + developer hub to fit two days; observability (M12)
  stays because ops questions always come up.
- **WS-DEV-1D** — the developer on-ramp, foundations only.
- **WS-OPS-1D** — assumes container fluency; jumps straight to pipelines, supply
  chain, scale, and tenancy.

Storage (M05) and batch (M06) are strong swap-ins for audiences that ask for them —
every module is self-contained, so any ascending selection works.

## Demo paths — SA-Demos showroom (separate category)

Demos are **not** workshop paths and never appear on the attendee index. The demo
flavor (`site-demo.yml`, presenter Say/Show/Do blocks per module) feeds a **separate
SA-Demos showroom** whose purpose is fluent, presenter-led demonstrations with
talk-and-show points — reusing all the module preparation without the lab framing.
*(Direction of 2026-07-11; build slice queued — see 06-BACKLOG "SA-Demos showroom".)*

| Demo path | Audience | Sequence |
|---|---|---|
| `DEMO-EXEC-45` | 45-minute executive demo (presenter-led) | M03 + M08 + M10 + M23 |

More demo paths (e.g. "OpenShift Advanced App Platform Demo") are composed as the
SA-Demos showroom lands.

## Module selection at provision time (planned)

Direction (2026-07-11): SAs choose **some modules or full** when provisioning, and
the attendee Showroom renders only the chosen set. Design queued (see 06-BACKLOG):
a module list in the provisioning values drives per-module AsciiDoc attributes, and
the nav/library include each module conditionally — one content source, filtered at
Showroom content-build time. Until that lands, selection is advisory: tell attendees
which modules their session includes.
