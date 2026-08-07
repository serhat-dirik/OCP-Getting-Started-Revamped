# parasol-fraud

A tiny Quarkus **fraud-scoring service**. It exists to be the *audience* of a token exchange in
the **Securing Apps with Keycloak** module: `parasol-claims` exchanges the caller's user token
for one scoped to `aud=parasol-fraud`, and this **bearer-only** service enforces that audience — so a
correctly down-scoped token is accepted and an attempt to escalate is refused.

```
   parasol-web ──(user token)──► parasol-claims ──(exchanged aud=parasol-fraud token)──► parasol-fraud
                                                                                          enforces aud=parasol-fraud
```

You can read it in ten minutes: one resource class, a deterministic score, no database.

## Endpoints

| Method + path | Purpose |
|---|---|
| `GET /api/fraud/score/{claimId}` | Deterministic fraud score (0–99) and risk band for a claim |
| `GET /q/health/live` | Liveness probe |
| `GET /q/health/ready` | Readiness probe |
| `GET /q/metrics` | Prometheus metrics |

The score is a pure function of the claim ID, so lab text can quote exact values:

```json
// GET /api/fraud/score/CLM-1001
{ "claimId": "CLM-1001", "score": 37, "risk": "low",  "model": "parasol-fraud-heuristic-v1" }
// GET /api/fraud/score/CLM-1005
{ "claimId": "CLM-1005", "score": 85, "risk": "high", "model": "parasol-fraud-heuristic-v1" }
```

## Security — unprotected by default

Like every Parasol app, this one ships with its OIDC tenant **disabled**
(`quarkus.oidc.tenant-enabled=false`). In every module except *Securing Apps with Keycloak* the
endpoints are anonymous and no auth server is contacted at startup.

That is deliberate: modules are independent, so no module may assume another one already
configured authentication.

### Turning protection on

The *Securing Apps with Keycloak* module makes it a real bearer-only resource server, per
attendee, through environment variables:

```properties
QUARKUS_OIDC_TENANT_ENABLED=true
QUARKUS_OIDC_AUTH_SERVER_URL=https://sso-workshop.<domain>/realms/realm-<user>
QUARKUS_OIDC_TOKEN_AUDIENCE=parasol-fraud   # accept ONLY tokens carrying aud=parasol-fraud
```

Two settings are already in `application.properties` so the module does not have to teach them:
`quarkus.oidc.application-type=service` makes it bearer-only, and
`quarkus.oidc.roles.role-claim-path=realm_access/roles` maps Keycloak realm roles, so an in-lab
`@RolesAllowed("claims-adjuster")` on `FraudResource.score` matches.

## Tech

- **Quarkus 3.33 LTS**, pinned in `pom.xml`.
- **Java 21**, JVM mode, `fast-jar` packaging.
- Minimal extensions, each earning its place: `quarkus-rest-jackson`, `quarkus-oidc` (disabled
  by default), `quarkus-smallrye-health`, `quarkus-micrometer-registry-prometheus`,
  `quarkus-opentelemetry` (exporter off).

## Local development

```bash
./mvnw quarkus:dev
curl -s localhost:8080/api/fraud/score/CLM-1001
curl -s localhost:8080/q/health/ready

# or package and run:
./mvnw -DskipTests package
java -jar target/quarkus-app/quarkus-run.jar
```

OIDC Dev Services are disabled, so dev mode and `./mvnw test` never start a Keycloak container.
The workshop always points OIDC at its shared Keycloak instead.

## How the image is built

GitOps builds it — there is no manual step. A BuildConfig and ImageStream in
`gitops/workshop-config/templates/parasol-images-build.yaml` clone this repository and push
`parasol-fraud:latest`. The `1.0` tag is an alias for `latest`, so the modules that pin `1.0`
resolve without anyone having run a build by hand.

```bash
# Rebuild after editing this app — moves latest and the 1.0 alias together:
oc start-build parasol-fraud -n ogsr-parasol-images --follow
```

## Container notes

- UBI9 multi-stage build: `ubi9/openjdk-21` for the build, `ubi9/openjdk-21-runtime` at runtime.
- Runs as numeric non-root **USER 185** on port **8080**. Files are copied `--chown=185:0` and
  group-readable, so it also runs under an arbitrary injected UID — which is what OpenShift's
  restricted security context does.

## Intentional flaws — do not fix

**None.** This service carries no deliberate fault — its whole curricular job is to be the
*audience* of a token exchange, and a second lesson hidden inside the scoring function would
only blur that.

The workshop's deliberate faults live elsewhere: a seeded vulnerable dependency on the
`parasol-claims` `seed-vulnerable` branch (*Trusted Software Supply Chain*), an N+1 query
endpoint on `parasol-claims` (*Observability, Health & Scale*), and the legacy patterns
throughout `parasol-legacy-claims` (*Application Modernization*).

### That claim is now checkable — it did not used to be

This section used to read *"None. This service is deliberately simple and correct."* On
2026-08-07 a field tester read `scoreFor` on JDK 21 and found it was neither. Both defects were
real, both are fixed, and each is pinned by a named test so the claim above is evidence rather
than assertion:

| Defect in the old `long` arithmetic | Symptom | Pinned by |
|---|---|---|
| `Long.parseLong(digits) * 37` overflowed for an 18-digit id, and `%` keeps the dividend's sign | `CLM-249299106394725033` scored **-95** and was published as risk **"low"** — the javadoc promised `[0,99]` | `scoreStaysInsideItsDocumentedRange`, `noClaimIdInTheFormerOverflowWindowEscapesTheRange` |
| A 20-digit id is one digit past `Long.MAX_VALUE`, so `parseLong` threw `NumberFormatException` | **HTTP 500** on caller-controlled path input | `oversizedClaimIdIsScoredNotAServerError` |

The fix reduces the digits with `BigInteger` — the same judgement that makes claim amounts
`BigDecimal` in `parasol-claims`: when a domain value can outgrow a primitive, use exact
arithmetic instead of hoping it will not. `BigInteger.mod` is never negative, so `[0,99]` now
holds by construction. `FraudResource.scoreFor`'s javadoc carries the full reasoning, including
why `Math.floorMod` would have hidden the bug rather than fixed it.

**No published value changed.** 600,008 claim ids were scored under both the old and the new
code, covering every id the workshop can produce (`CLM-1`…`CLM-100000`, the `CLM-1001`…`CLM-1030`
seeds, the no-digit hash branch) plus a half-million random ids from the range the old code
handled correctly: **zero differences**. The new code differs only where the old code was
already wrong or threw. `CLM-1001` still scores 37/low and `CLM-1005` still scores 85/high, so
lab text, verify scripts and captured output are unaffected.

### Why these were fixed rather than declared teaching flaws

Overflow and unhandled input *are* good teaching material, and shipping deliberate faults is an
established pattern here — so this was a real choice, not a default. Three things decided it:

1. **No module could reach it.** A teachable flaw has to be triggerable by a lab. Every claim id
   the workshop generates has one to four digits; the overflow window starts at eighteen. The
   flaw would have existed only in prose.
2. **It failed silently, in the wrong direction.** The workshop's real faults are *observable* —
   a slow trace, a red scan gate, legacy code you can read. This one returned a well-formed
   `200` with a nonsense number and called it low risk.
3. **An undeclared flaw behind a README claiming correctness is just a bug.** Attendees read
   this code in the IDE; that is exactly why the false claim cost more than the defects did.
