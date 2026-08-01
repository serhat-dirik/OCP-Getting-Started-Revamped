# parasol-service-template — the Parasol golden path

A **Red Hat Developer Hub / Backstage Software Template** that scaffolds a
paved-road Parasol microservice. It is the golden path taught in the *Developer Hub & Golden
Paths* module: fill in a short form and get a Quarkus / Java 21 service that already has
everything the workshop expects.

## What it scaffolds

`skeleton/` is a minimal, buildable Quarkus service that mirrors the
`parasol-claims` conventions:

- **Quarkus 3.33 LTS**, **Java 21** (`maven.compiler.release=21`), `fast-jar`.
- Health probes (`/q/health/*`), Prometheus metrics (`/q/metrics`), and
  OpenTelemetry — **on by default** (exporter off until *Observability, Health & Scale*).
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

## Publish step — deliberately left as a placeholder

The **publish** and **register** steps in `template.yaml` are a documented placeholder rather
than a fixed choice.

Publishing into the workshop's Gitea can go through either the community `publish:gitea` dynamic
plugin or the generic `publish:git` fallback, and which one is available depends on the Developer
Hub version installed on your cluster. Rather than hardcode a guess, the template ships both
blocks commented out; whoever wires it verifies which loads on the live instance and uncomments
that one.

Until then the template scaffolds into the workspace without creating a remote repository, which
is enough to demonstrate the form-to-service path.

## Verifying the skeleton

Substitute the placeholders for real values and build it:

```bash
./mvnw -B -ntp clean package
```

It compiles clean and produces a `fast-jar`, with its smoke tests passing.
