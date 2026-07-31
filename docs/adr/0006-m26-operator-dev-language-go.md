# ADR-0006: M26 Operator Development — Go (operator-sdk) for the graded lab, Java as take-home

Date: 2026-07-15 · Status: **RETIRED 2026-07-15** — M26 (Operator Development) cut by owner before any build; this decision is moot, kept only as a research record · Owner: PM (research by research-analyst)

> **RETIRED — M26 was cut.** The owner dropped M26 (Operator Development Deep-Dive) on 2026-07-15 as too
> advanced, before any content or entry-state was built. This ADR's Go-vs-Java decision is therefore moot
> and retained only as a record of the research. If M26 is ever revived, re-open and re-verify (the tooling
> facts below were current 2026-07-15). Original intent: the reasons for Go were tooling-forced, not preference.

## Context

M26 (Operator Development Deep-Dive, 120-min double slot) has attendees scaffold an operator with
`operator-sdk`, implement a reconcile loop for a `ClaimsArchive` CRD that owns a CronJob + PVC, run it
locally then in-cluster, and package it as an OLM bundle. The spec (§M26) explicitly defers the
implementation language to a research-stage decision "by audience data" and asks for it in an ADR.
Verified live on the build cluster + upstream docs (2026-07-15, `docs/research/m26-build-note.md`):

- **`operator-sdk` no longer scaffolds Java.** Since v1.37.0 the SDK delegated non-Go languages; current
  upstream `operator-sdk` (v1.42.x, `go/v4` plugin) scaffolds Go (plus Helm/Ansible operators), not Java.
- **No Red Hat-supported `operator-sdk` on OCP 4.21.** The last RH-shipped SDK came with 4.18 (v1.38.0);
  4.21 ships none — so the lab uses the **upstream** CLI regardless of language, and teaches **OLM v1**
  (GA, live here, CLI-only in 4.21) as the modern install path (ties M25).
- **The canonical Kubebuilder tutorial IS this lesson.** The upstream "CronJob controller" tutorial builds
  exactly a controller that owns Jobs — a near-perfect match for `ClaimsArchive` owning a CronJob + PVC,
  including ownerReferences/GC, status conditions, and events.
- **Toolchain cost is low in Go.** The existing Dev Spaces UDI (`udi-rhel9:3.29`, already pre-pulled for
  M03) ships Go + make + oc/kubectl + helm; the only net-new is the `operator-sdk` binary + a warm module
  cache — a thin derived image, not a big new base.

## Decision

Teach the **graded lab in Go** with upstream `operator-sdk` (v1.42.x, `go/v4`). Carry a **documented
take-home path in Java** (Quarkus Operator SDK / Fabric8 Java Operator SDK) for Java-leaning teams who want
to continue in their primary language, clearly marked as not-graded. Package the result as an **OLM v1**
bundle; treat cluster-scoped bundle *install* as an [INSTRUCTOR-DEMO] (attendees lack CRD / cluster-
extension create rights by design — see the entry-state RBAC in the build note).

## Consequences

- **Audience filter is real and intended.** M26 already carries a "programming comfort" prerequisite; Go
  sharpens it. Mitigate with a heavily-commented reconcile loop, copy-paste-safe steps, and the framing
  that controllers are the platform's own pattern (everything all week was a reconcile loop) so the
  *pattern* lands even for a non-Go reader.
- **Consistent with the ecosystem norm.** Go is the Kubernetes-native operator language; attendees who go
  on to write operators will meet Go — this is honest to the real world.
- **Java identity preserved elsewhere.** The Java take-home, plus M22/M23/M24 apps staying Quarkus, keeps
  the workshop's Java-primary identity; M26 is a deliberate single exception.
- **Reversible until content lands.** Switching to a Java graded path later means a different toolchain +
  workspace image and diverging from the canonical Kubebuilder tutorial (more authoring + maintenance for
  us), but stays in-language for attendees.

## Rejected: Java-first (Quarkus Operator SDK / JOSDK) as the graded path

Stays in the attendees' primary language, but `operator-sdk` cannot scaffold it (losing the SDK's guided
`init`/`create api` flow and the canonical tutorial), we own more of the lab from scratch, and the
toolchain/workspace image diverges from the Go one. Kept as the documented take-home instead.
