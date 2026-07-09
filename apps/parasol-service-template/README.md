# parasol-service-template — the Parasol golden path

A **Red Hat Developer Hub / Backstage Software Template** that scaffolds a
paved-road Parasol microservice. It is the golden path taught in module **M10
(Developer Hub & Golden Paths)**: fill a short form and get a Quarkus 3.33 /
Java 21 service that already has everything the workshop expects.

## What it scaffolds

`skeleton/` is a minimal, buildable Quarkus service that mirrors the
`parasol-claims` conventions:

- **Quarkus 3.33 LTS**, **Java 21** (`maven.compiler.release=21`), `fast-jar`.
- Health probes (`/q/health/*`), Prometheus metrics (`/q/metrics`), and
  OpenTelemetry — **on by default** (exporter off until M11).
- A UBI9 multi-stage `Containerfile` (`ubi9/openjdk-21:1.23`), non-root USER 185.
- A Dev Spaces `devfile.yaml` pinned to **JDK 21**.
- A Backstage `catalog-info.yaml` (auto-registered), an `openshift/buildconfig.yaml`,
  and a starter `GET /api/info` endpoint with a smoke test.

## Parameters

| Parameter | Required | Purpose                                             |
|-----------|----------|-----------------------------------------------------|
| `name`    | yes      | Service name (lowercase, `^[a-z][a-z0-9-]{2,40}$`)  |
| `owner`   | yes      | Backstage group that owns the service (default `parasol`) |

Placeholders in `skeleton/` use the Backstage `${{ values.name }}` /
`${{ values.owner }}` syntax and are rendered by the template's `fetch:template`
step.

## Publish step — deliberately unresolved (M10 builder)

The template's **publish + register** steps are left as a documented placeholder
in `template.yaml`. Publishing into the workshop Gitea needs either the community
`publish:gitea` dynamic plugin (`scaffolder-backend-module-gitea`, support in
RHDH 1.10 is TODO-verify) or the generic `publish:git` fallback. **The choice is
not guessed here** — the M10 builder verifies which loads in the live RHDH and
uncomments the matching block. Until then the template scaffolds into the
workspace (fetch step) without creating a remote repo.

## Proven

The skeleton compiles: substitute the placeholders (`${{ values.name }}` →
a real name) and run `./mvnw -B -ntp clean package` — `BUILD SUCCESS`, smoke
tests green, `fast-jar` produced. See the app-developer build report.
