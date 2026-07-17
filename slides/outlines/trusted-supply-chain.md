# M08 — Trusted Software Supply Chain

## Slide: The audit Parasol couldn't pass

- Pipeline builds and deploys reliably
- Auditor: what's inside this image?
- Auditor: who built it — prove it
- "It builds" ≠ "it's trustworthy"
- Three controls answer all three questions

Notes: Open with the business pain. Parasol's pipeline builds and deploys the claims service reliably, and then a supplier security audit asks three questions the team cannot answer: what dependencies are in this image, who built it, and can you prove the running image is the one your pipeline produced. "It builds" is not the same as "it is trustworthy." This module adds the three controls that answer those questions — a vulnerability scan gate, image signing with provenance, and a software bill of materials — and makes the cluster refuse to run anything unsigned. Entitlement note: RHACS and RHTAS are part of the Advanced Developer Suite (RHACS is also in Platform Plus), but two of the controls — Tekton Chains signing and the native ImagePolicy admission gate — ship with OpenShift itself.
Visual: A "PASSED build" box on the left with three red question marks (what's inside? / who built it? / prove it), an arrow to a "TRUSTWORTHY artifact" box on the right.

## Slide: You ship your dependencies

- Your code is a fraction of what you deploy
- The rest: runtime, libraries, base OS layers
- Log4Shell: is it in anything we ship?
- Answer in minutes, not a weekend
- SLSA grades your build process, not your code

Notes: The idea under the whole module: the code your team wrote is a small fraction of what you deploy. The claims image is mostly other people's code — the Quarkus runtime, transitive libraries, base-OS layers — pulled in at build time. That's normal and good, and it's the attack surface. When a critical flaw lands in a widely used library (Log4Shell in log4j-core, December 2021, is the canonical case), the question isn't "did we write the bug," it's "is it in anything we ship, and can we find out in minutes." One-paragraph SLSA: it's an industry framework that grades how trustworthy your build process is — not your code, your process — climbing from "build on a hosted system" to "produce signed provenance" to "make it tamper-resistant." You don't memorize levels; a pipeline that builds on the cluster, signs what it produces, and attaches provenance is already climbing — which is exactly what this module gives you.
Visual: A container image drawn as an iceberg — a thin "your code" sliver above the waterline, a large "dependencies + base OS" mass below.

## Slide: Three artifacts, three questions

- Signature: intact, and it's ours
- Attestation: how it was built (SLSA provenance)
- SBOM: what's inside (every component)
- People conflate them — they're different facts
- You need all three; they reinforce each other

Notes: Three artifacts travel with a trustworthy image and answer three different questions — pin the distinction because people conflate them constantly. The signature proves the image is intact and came from us (a cryptographic signature over the digest). The attestation is signed provenance — how the image was built: the builder, the source, the steps, the timestamps, as a SLSA statement. The SBOM is what's inside — every component and version. A signature with no SBOM tells you the image is authentic but not what's in it; an SBOM with no signature tells you what a build contained but not that this image is that build. You need all three, and they reinforce each other: the attestation is signed, the SBOM can be attested, and the signature is what an admission gate checks.
Visual: Reuse concept diagram m08-...-01 (the trust triangle / pipeline) — signature / attestation / SBOM as three labelled artifacts beside the image.

## Slide: Gate at build, admit at run

- Gate (build): scan, fail the build on a CVE
- Shift-left: the developer sees it in their run
- Admission (run): cluster verifies signature at pull
- Unsigned image → refused, no matter what
- Mature answer is both, not either

Notes: There are two places to stop a bad image, and they're not interchangeable — a mature supply chain uses both. Policy-as-gate runs inside the pipeline: build the image, scan it, fail the build if it violates policy. That's where you catch a vulnerable dependency before it's ever published, and its value is shift-left — the developer who introduced the flaw sees it in their own pipeline run, not in a production incident. But a gate only helps if every image goes through the pipeline. Policy-as-admission closes that gap at the cluster: OpenShift's native ImagePolicy tells the node to verify a signature before it will pull an image into a namespace, so an image that never went through your signing pipeline is refused at pull time. The gate is a policy you run; admission is a policy the platform enforces whether or not anyone remembered to run the gate.
Visual: Two gates in series — a pipeline "scan gate" (fails a red image) and a cluster "admission gate" (refuses an unsigned image), with a caption "both, not either."

## Slide: A gate you can trust must be deterministic

- "Any fixable CVE" fires on drifting base-OS CVEs
- Same image: pass Monday, fail Friday
- Scope the gate to one policy category
- Keys on the seeded dependency, not the base
- Remove the dependency → green, every time

Notes: A gate that fails intermittently trains people to ignore it — so determinism matters. A default RHACS policy like "Fixable Severity at least Important" fires on any fixable CVE in the image, including base-OS CVEs that appear and disappear as the vulnerability feed updates. That's correct for a real security program but makes a teaching gate non-deterministic: the same image can pass Monday and fail Friday. So the lab's gate is scoped to a single policy category containing one deterministic, enforced policy — "Block Log4Shell." It fires on exactly one thing: the seeded log4j-core dependency. Remove that dependency and the gate goes green, reliably. This also sets up an honest point about base images: bumping the older UBI tag is good hardening (fewer base-OS CVEs), but it is not what turns this gate green — the vulnerable dependency is.
Visual: A dial labelled "gate scope" turned from "any CVE (noisy, non-deterministic)" to "one policy category (deterministic)"; a small green check beside "remove the dependency."

## Slide: Signing for free — Tekton Chains

- Chains signs every pipeline-built image
- No per-build wiring — it just watches
- Emits SLSA provenance automatically
- Key-based here; keyless (RHTAS) is the enterprise path
- Signature + provenance stored beside the image

Notes: Signing sounds like work; here it's automatic. Tekton Chains — a component of OpenShift Pipelines — watches every build TaskRun and signs the image it produced, with no per-build wiring, and emits a SLSA provenance attestation describing how the image was built (builder, source, steps, timestamps). It stores the signature and provenance in the registry beside the image, as extra tags derived from the digest, so they travel with the image. The lab signs with a cosign key pair (private key in the cluster, public key verifies) because it's deterministic and needs no per-build identity. The enterprise alternative is keyless — Red Hat Trusted Artifact Signer (Fulcio short-lived certs + a Rekor transparency log) — which removes long-lived keys at the cost of an OIDC dependency and log retention. Reach for keyless when you need public verifiability, not by default.
Visual: A build step with a small "Chains" badge auto-attaching a .sig and .att to the image icon; a side note "key-based (lab) vs keyless / RHTAS (enterprise)".

## Slide: What you'll do

- Run the pipeline — watch the scan block Log4Shell
- Find log4j-core@2.14.1 in the SBOM (one jq)
- Remove the dependency — gate goes green
- See Chains signed it; read the provenance
- Watch the cluster refuse an unsigned image

Notes: Set expectations for the hands-on, all in your own -cicd project. You run the supply-chain pipeline on a branch seeded with a known-bad dependency and watch the build succeed and then the scan turn the run red — "Block Log4Shell," CVSS 10, in log4j-core 2.14.1. You generate a CycloneDX SBOM and find that exact component with a one-line jq query — the same query you'd run the day the next big CVE lands. You remove the dependency in your fork, re-run, and watch the gate go green with no base-image change. You confirm Tekton Chains signed every build and attached SLSA provenance, and you see how a native ImagePolicy makes the cluster refuse to pull an unsigned image. Two beats — the cosign verification and the admission block — are instructor-run (the terminal has no cosign, and ImagePolicy is a cluster resource), but you verify the pieces hands-on.
Visual: Numbered arc strip: run → scan blocks → find in SBOM → fix → signed → admission refuses unsigned.

## Slide: Map to your org — and when not

- Next Log4Shell: query, or a weekend of grep?
- Do you sign — and does anything check it?
- Gate, admission, or both — which is missing?
- Don't gate on non-deterministic policy people can't act on
- Don't sign images you never verify

Notes: Land the transfer and stay honest. Discussion prompts: when the next Log4Shell lands, how fast can you answer "are we affected" — a stored-SBOM query, or a team grepping build files by hand; whether your org signs images today and, if so, where the signature is actually enforced (admission on every cluster, or nowhere); and where the gate should live for a service that matters — pipeline, admission, or both — and which one is missing today. Then the credibility close on restraint: don't gate on non-deterministic policy in a place people can't act (route the noisy "any CVE" policy to a report, not a hard failure); don't sign images you never verify (signing without enforcement is overhead); keyless is powerful but not free (OIDC + log retention); and an SBOM is a snapshot, not a subscription — it's only as useful as the process that keeps and re-scans it.
Visual: Two-column card "query / fire drill" and "signed + enforced / signed + ignored", with a footnote pointer to the GitOps and Registry-governance modules.
