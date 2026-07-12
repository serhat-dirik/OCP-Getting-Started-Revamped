# M23 build note — Agentic AI on OpenShift

Date: 2026-07-12 · Author: research-analyst · Spec: `Project-Shared/instructions/02-MODULE-SPECS.md` **§M23 "Agentic AI on OpenShift"** (Gen 3 numbering) · Entitlement: **[ADD-ON]** (Red Hat AI — separate subscription; no `[OCP]` module may depend on it). Reconciles **ADR-0004** (topic: "M23 shared Llama Stack / MaaS", file-slug `0004-m22-...` per the 2026-07-10 renumber).

Method: READ-ONLY live build cluster `ocp-ws-revamped` (OCP 4.21.22 / k8s 1.34.8) as `admin` (never user5, no mutations): `oc get packagemanifest/csv/crd/secret/olsconfig`. docs.redhat.com 403s on direct fetch → product facts via WebSearch against docs.redhat.com / developers.redhat.com / redhat.com blog + live OLM packagemanifests. Repo inspection: `platform-portfolio/`, `gitops/entry-states/`, `apps/`, `versions.yaml`, `docs/research/field-sourced-content-note.md`. OldContent: `agentops-in-prod-showroom`, `parasol-insurance` (redhat-ads-tech). `versions.yaml` `rhoai`/`lightspeed` re-confirmed live today; **not edited** (both <60 days, still accurate).

## Verified versions

| Product / capability | Version / status | API / mechanism | Source | Date |
|---|---|---|---|---|
| OpenShift | 4.21.22 (k8s 1.34.8) | stable-4.21 | `oc version` (live) | 2026-07-12 |
| **Red Hat OpenShift AI** (RHOAI) `[ADD-ON]` | GA head **3.4.2** on `stable-3.x` (default); `beta`→**3.5.0-ea.1** (EA, not GA); bare `stable`→**2.25.8** (2.x TRAP — never use) | package `rhods-operator` (Red Hat Operators); **NOT installed** on cluster | live packagemanifest; versions.yaml `rhoai` | 2026-07-12 |
| RHOAI doc-set | 3.4 GA published; 3.5 published (EA) | docs.redhat.com `.../red_hat_openshift_ai_self-managed/3.4` | search (403 on fetch) | 2026-07-12 |
| **Llama Stack** (in RHOAI 3.4) | ODH Llama Stack **0.6.0.1+rhai0**; **Technology Preview** | `LlamaStackDistribution` CR; activated via the LlamaStack operator (DataScienceCluster component) | RHOAI 3.4 "Working with Llama Stack" | 2026-07-12 |
| **Responses API** | `/v1/responses`; **Developer Preview** (3.4) | providers = agents+inference+vector; OpenAI-client compatible, citation metadata | RHOAI 3.4 relnotes; developers.redhat.com 2026-03-09 | 2026-07-12 |
| Llama Stack **Connectors** (MCP registries) | New in 3.4 | register MCP/tool registries by `connector_id` | RHOAI 3.4 relnotes | 2026-07-12 |
| **MCP tools** in Llama Stack | supported (tool groups); guardrail enforcement is `llm_input`/`llm_output` only (no tool-level yet) | register MCP servers as tools | RHOAI 3.3/3.4 Llama Stack examples | 2026-07-12 |
| Vector stores (RAG) | **Milvus** (remote, production) + **PostgreSQL/pgvector** (default metadata store since 3.2) | Llama Stack vector-io provider | RHOAI 3.4 Llama Stack | 2026-07-12 |
| **Guardrails — TrustyAI FMS Orchestrator** | **GA** | `GuardrailsOrchestrator` CR; built-in **regex detectors** (SSN/CC/email) as a lightweight HTTP **sidecar**, `enableBuiltInDetectors: true`; `trustyai_fms` Llama Stack safety provider | docs "Ensuring AI safety with guardrails" 3.4/3.5; trustyai.org | 2026-07-12 |
| **MaaS — RHOAI-native** (the product) | **GA since RHOAI 3.4** | OpenAI-compatible `/v1/chat/completions` AI gateway; native token quotas / rate limits / API keys; built on **Connectivity Link** (Kuadrant/Envoy/Istio) | redhat.com blog "Scaling enterprise AI…3.4"; docs "Govern LLM access with MaaS" | 2026-07-12 |
| **MaaS — workshop runtime** (what we actually call) | **LiteMaaS** (LiteLLM) on `maas-rdhp`; model **qwen3-14b** | endpoint `https://maas-rhdp.apps.maas.redhatworkshops.io/v1`; OpenAI/vLLM-compatible; per-lab virtual keys `sk-…`; token via `openshift-lightspeed/credentials` key `apitoken`; `/v1/models` egress 200 (M06 2026-07-09) | repo `stacks/ai-assist/apps/openshift-lightspeed.yaml`; `field-sourced-content-note.md` | 2026-07-12 |
| OpenShift **Lightspeed** `[OCP]` | **v1.1.1** (`stable`) **INSTALLED** | `OLSConfig` `ols.openshift.io/v1alpha1` name `cluster`, provider `rhoai_vllm`→MaaS; **LIVE config currently `azure_openai`/gpt-4 (drift — see risks)** | live packagemanifest + `oc get olsconfig cluster` | 2026-07-12 |
| Quarkus + LangChain4j | Quarkus **3.33.2.1 LTS** (JDK 21); `quarkus-langchain4j-mcp` **v1.10.0** (2026-05-13), MCP client since 0.23.0 | STDIO / HTTP-SSE / WebSocket transports; auto `ToolProvider` aggregation; unified RAG + vector stores | versions.yaml `quarkus`; quarkiverse docs | 2026-07-12 |
| Tempo / OpenTelemetry (agent obs tie, M12) | Tempo **v0.21.0-2** + OTel **v0.152.0-1** INSTALLED | OTLP spans → TempoMonolithic | live CSV (M18 note) | 2026-07-12 |

**Headline (spec-critical):** the agentic stack the spec asks for is **almost entirely net-new**. On the cluster today, the ONLY AI thing wired is **OpenShift Lightspeed → MaaS** (LiteMaaS `qwen3-14b`). There is **no RHOAI, no Llama Stack, no TrustyAI/guardrails, no KServe/inference, no vector DB** (only CRD `olsconfigs.ols.openshift.io` exists; `rhods-operator` is catalog-available, not installed). `versions.yaml` has **no `llama_stack` / `maas` / `guardrails` entries** — a gap M23 build must fill.

## Cluster / repo reality (verified live 2026-07-12, read-only)

- **`ai-assist` stack = OpenShift Lightspeed only** (`platform-portfolio/stacks/ai-assist/kustomization.yaml` → one app `openshift-lightspeed`). Everything M23 needs (Llama Stack, guardrails, vector DB, MCP servers) is a **net-new component + stack** build.
- **Entry-states stop at `m14`** — there is **no `gitops/entry-states/m23/`**. The spec's `{user}-ai` ns + MaaS creds + shared/per-user Llama Stack + 2 MCP servers + small vector DB are all net-new.
- **`parasol-agent` and `apps/mcp-servers/` do NOT exist yet.** `apps/README.md` reserves them (`parasol-agent` = "Quarkus + LangChain4j: model calls, RAG, MCP tool use", `mcp-servers/` = `claims-db`, `policy-docs`), tagged with **old** numbering ("M22", "M28" → decode by topic: M22-old = Agentic AI = **M23**; M28-old = AI-Assisted Dev = **M24**). `apps/parasol-claims/pom.xml` has **zero** LangChain4j/OpenAI deps — the agent is a clean-sheet Quarkus service.
- **The proven MaaS-token plumbing already exists** (`gitops/entry-states/m06/templates/maas-credentials.yaml`): a hook Job with a least-privilege SA (`resourceNames`-pinned Role reading only `openshift-lightspeed/credentials` key `apitoken`) copies the bearer into a per-user `maas-credentials` Secret + a `maas-config` ConfigMap (`endpoint`, `model`). **Reuse this verbatim for `{user}-ai`.**
- **`credentials` secret has TWO keys** (`Bearer`, `apitoken`); **live `OLSConfig` is currently `azure_openai` / gpt-4**, NOT the git-intended `rhoai_vllm`/`maas-rhdp`/`qwen3-14b` — a drift to reconcile at build (see risks).

## Spec deltas

- **MaaS is now a GA product, not just "our endpoint."** The spec (and ADR-0004) treat MaaS as an ad-hoc OpenAI-compatible URL. As of **RHOAI 3.4 it is GA**: an integrated AI gateway (Connectivity Link/Kuadrant/Envoy) with native **token quotas, rate limits, per-key API keys** — which directly answers the spec's "MaaS quota/cost ×30 users" watchout and strengthens the "govern: who may call which model, cost/quotas" beat. **But our runtime is LiteMaaS (LiteLLM) on `maas-rdhp`, not RHOAI-native MaaS** — teach the governance story as [ADD-ON] product capability, run against LiteMaaS.
- **Responses API is only Developer Preview** (Llama Stack itself is Technology Preview). The spec headlines "Llama Stack (Responses API)". Viable to teach, but the **ADR-0004 Quarkus-LangChain4j-direct fallback is now the safer graded path** — and it fully covers MCP + RAG + tools (`quarkus-langchain4j-mcp` 1.10.0), so the module's three teaching goals stand without depending on a Dev-Preview surface.
- **Guardrails packaging resolved:** spec says "verify current packaging." **FMS Guardrails Orchestrator = GA**; the deterministic, GPU-less "PII block" beat is the built-in **regex detector** sidecar (`enableBuiltInDetectors: true`, SSN/CC/email) — no model-serving/GPU required. Wire via Llama Stack `trustyai_fms` provider, or as a direct shield in the fallback path.
- **Profile name mismatch:** spec says profile `core+ai`; the actual bootstrap profile/stack is **`ai-assist`** (`field-sourced-content-note.md` L133: `--profiles core[,ai-assist,…]`). `core+ai` does not exist — M23 extends the `ai-assist` stack (or a new `ai-agentic` stack).
- **Entry-state over-assumes:** "Llama Stack deployed shared/per-user; `parasol-agent` + 2 MCP servers source in Gitea; small vector DB." **None exists.** Module-independence requires the m23 entry-state to materialize all of it without assuming any prior module ran.
- **`[INSTRUCTOR-DEMO if RHOAI present]`** is the correct hedge — RHOAI is **not** installed and is heavy (GPU for in-cluster serving/guardrail models). Default path = MaaS + Llama Stack (remote provider, GPU-less) + regex-detector guardrail; in-cluster RHOAI stays documented-not-defaulted (spec already says this).
- **ADR-0004 needs a light refresh** (decisions still sound): "RHOAI 3.3 is current" → **3.4** (`stable-3.x`=3.4.2; 3.5 EA); MaaS "our endpoint" → **GA product** (plus the LiteMaaS-runtime distinction); Responses API = **Dev Preview**; "hard re-verify at M22 build" → **M23**; FMS Orchestrator GA confirmed.

## Approach recommendations (max 5)

1. **Default runtime = one shared `LlamaStackDistribution`** with a remote-vLLM/OpenAI provider → **LiteMaaS `qwen3-14b`** (GPU-less), per-user isolation via per-user vector-store IDs + per-user MCP pods (ADR-0004); keep the **Quarkus LangChain4j direct-to-MaaS fallback** as the graded path since Llama Stack is TP and Responses API is Dev Preview.
2. **Net-new GitOps, no imperative installs:** extend the **`ai-assist`** stack (not `core+ai`) with net-new `components/{llama-stack, trustyai-guardrails, vector-db}` + net-new `gitops/entry-states/m23/` (Helm, per-user `{user}-ai` ns, MaaS creds via the **M06 hook pattern**, 2 MCP pods, a small vector store).
3. **Guardrail beat = FMS Orchestrator (GA) built-in regex detector sidecar** (SSN/CC/email, `enableBuiltInDetectors`) — deterministic, no GPU/model-serving; the "PII input blocked / off-topic output filtered" demo lands without RHOAI's heavy path.
4. **Build `parasol-agent` + `apps/mcp-servers/{claims-db,policy-docs}` net-new as Quarkus LangChain4j** (apps/README already reserves them); MCP over HTTP-SSE (`quarkus-langchain4j-mcp` 1.10.0); observe token/latency/traces via **OTel → the already-installed Tempo** (ties M12), NOT MLflow.
5. **Disambiguate + de-risk:** M23 = agent building / RAG / MCP-tools-are-your-APIs / guardrails; **M24 = MCP coding-assistant driving the cluster** (shared `mcp-servers/`, different job). Keep everything **model-agnostic** (qwen3-14b vs llama-scout-17b differ across infra) and **temperature-0 / seeded** for reproducible demos.

## Mining results

- **`OldContent/repos/agentops-in-prod-showroom`** (rhpds, license none) → **narrative/UX ONLY**, and the spec's explicit non-overlap target. TAKE: the "multi-agent apps fail *distributedly*" hook, the **observability-gap / black-box** framing, tool-call tracing story, PII-masking + **safety-shields** framing, RAG **tiered boosting** idea (`pages/03-module-01-agentic-app.adoc`). **DISCARD ALL tech** — it is Python/**LangGraph**/FastAPI/**MLflow**/pgvector; our stack is Quarkus LangChain4j + Llama Stack + OTel/Tempo. Non-overlap: they *observe/eval a prebuilt* agent; **M23 builds one**. Re-implement, credit (CREDITS.md).
- **`OldContent/repos/parasol-insurance`** (redhat-ads-tech, license none) → domain narrative + `model/Claim.java` + `model/Email.java` + **`EmailRouter.java` / `EmailGenerator.java`** LLM email-triage story (its AI calls go to an OpenAI-compatible/LiteLLM endpoint — **not** LangChain4j). TAKE the Parasol AI domain + routing narrative; **re-implement with Quarkus LangChain4j**. Ideas only, credit.
- **`adv-app-platform-demo-showroom` M7** (AI-enhanced apps / email triage; `oldcontent-mining-index.md` §4) → demo Say/Show/Do arc for the "modernize (M22) then infuse AI (M23)" pairing.
- **docs.redhat.com RHOAI 3.4** — "Working with Llama Stack" ch.3–4 (deploy server, **RAG + MCP** examples), "Ensuring AI safety with guardrails", "Govern LLM access with Models-as-a-Service" → authoritative CR/API citations (anchor to **3.4**).
- **developers.redhat.com** — "Automate AI agents with the Responses API in Llama Stack" (2026-03-09), "Deploying agents with Red Hat AI: OpenClaw" (2026-04-14), "Model-as-a-Service: run your own private AI API" (2026-06-12) → current agent tutorials + MaaS-key handling.
- **In-repo (no external credit):** `gitops/entry-states/m06/templates/maas-credentials.yaml` (per-user MaaS-token copy pattern) · `platform-portfolio/components/openshift-lightspeed/` (`rhoai_vllm` OLSConfig + `credentials` Secret contract) · `platform-portfolio/values/README.md` (the `credentials`/`apitoken` contract).

## Open risks

- **Fastest-moving area — hard re-verify rule (CLAUDE.md rule 1):** Llama Stack **TP**, Responses API **Dev Preview**, Connectors new in 3.4; ODH LS `0.6.0.1+rhai0` will move; RHOAI 3.5 is in EA (`beta`→3.5.0-ea.1). Re-verify every name/API/version at build.
- **RHOAI not installed → nothing verifiable live.** All `LlamaStackDistribution` / `GuardrailsOrchestrator` / vector-store / MCP behavior, CR fields, and console paths carry `// TODO(verify-on-cluster)` + `[CAPTURE-VERIFY]` until an `ai`/`ai-assist` profile with RHOAI (or a standalone Llama Stack) is up. **GPU reality:** MaaS is remote (GPU-less OK); in-cluster RHOAI serving/guardrail-*model* paths need GPU — default MUST stay MaaS + regex-detector.
- **MaaS token↔endpoint drift (verified live):** `OLSConfig cluster` = `azure_openai`/gpt-4, while git intent + m06 hardcode = `rhoai_vllm`/`maas-rhdp`/`qwen3-14b`; `credentials` has 2 keys (`Bearer`, `apitoken`). The "reuse Lightspeed's `apitoken` as the MaaS bearer" pattern must re-verify the token↔endpoint pairing at build. LiteMaaS keys are **short-lived (RHDP)** → 401 graceful-degradation like M01 Lightspeed.
- **MaaS quota/cost ×30:** RHOAI-native MaaS does per-key quotas/rate-limits natively, but the runtime is **LiteMaaS virtual keys** — confirm per-attendee token budget for a 90–120 min AI module (open in `field-sourced-content-note.md`); prefer per-user virtual keys or a gateway limit.
- **Two "MaaS" + two models:** RHOAI-native MaaS (GA product) vs LiteMaaS (runtime); `qwen3-14b` (workshop wiring) vs `llama-scout-17b` (FSC default). Content must disambiguate and stay model-agnostic. `litellm-rhpds` was **decommissioned 2026-06-21** — treat any doc citing it as stale; pin `maas-rdhp`.
- **Big net-new surface:** `ai-assist` extension + shared Llama Stack + 2 MCP servers + vector DB + `parasol-agent` + `apps/mcp-servers/` + `gitops/entry-states/m23/` + ws-meta + verify — all clean-sheet. This is the spec's flagged **early spike** ("M23: Llama Stack packaging") — do it before bootstrap freeze.
- **ADR-0004 refresh needed** (decisions sound; facts stale): RHOAI 3.3→3.4, MaaS→GA product + LiteMaaS note, Responses API=Dev Preview, "M22 build"→M23.
- **`versions.yaml` gap:** no `llama_stack` / `maas` / `guardrails` entries. `rhoai` (3.4.2 / `stable-3.x`) + `lightspeed` (1.1.1 / `stable`) **RE-CONFIRMED live today**, still <60 days → **not edited**; but `rhoai` note text says "re-verify at **M22** build" (topic = M23) — fix at next touch and add the three AI entries.

## Builder / platform appendix

**Decisions for the owner:** (1) **Runtime default** — shared `LlamaStackDistribution` (remote-MaaS provider) as primary vs Quarkus-LangChain4j-direct as primary with Llama Stack as the "product surface" demo. Given TP/Dev-Preview maturity, recommend **LangChain4j-direct is the graded lab spine; Llama Stack is the shared showcase** (both hit the same MaaS + MCP + regex-guardrail). (2) **Guardrail** — regex-detector sidecar (recommended, GPU-less, deterministic) vs a model-based detector (needs serving). (3) **Vector store** — pgvector (lighter, reuse claims Postgres pattern) vs Milvus (production story). (4) **Shared vs per-user Llama Stack** — ADR-0004 says shared + per-user vector-store IDs + per-user MCP pods; confirm ×30 footprint. (5) **Stack name** — extend `ai-assist` vs a new `ai-agentic` stack.

**Platform (platform-engineer):** net-new `platform-portfolio/components/{llama-stack, trustyai-guardrails, vector-db}` (+ optional in-cluster RHOAI via `rhods-operator` `stable-3.x`, instructor-only); wire into the **`ai-assist`** app-of-apps; profile the spec calls `core+ai`. Net-new `gitops/entry-states/m23/` (Helm, like `m05`/`m06`): `{user}-ai` ns, **reuse the m06 MaaS-credentials hook** (SA + `resourceNames`-scoped Role on `openshift-lightspeed/credentials` + copy Job) → per-user `maas-credentials` Secret + `maas-config` ConfigMap; 2 MCP pods (`claims-db`, `policy-docs`); a per-user vector store + seeded policy-doc embeddings; `ws-meta.yaml` (`conflictsWith` same-ns modules; `ws reset` purges `{user}-ai`).

**App/image:** build `apps/parasol-agent` (Quarkus 3.33 LTS / JDK 21, `quarkus-langchain4j-openai` + `quarkus-langchain4j-mcp` 1.10.0, OTLP export on) targeting the MaaS base-URL; `apps/mcp-servers/claims-db` (reads the `CLM-1001..CLM-1030` dataset) + `apps/mcp-servers/policy-docs` (RAG source) — MCP over HTTP-SSE. Reuse M22 legacy-claims → "modernize then infuse AI" arc.

**Lab arc (dual-path where genuine):** chat endpoint via MaaS (CLI curl `/v1/chat/completions` ‖ Console deploy) → RAG ingest + grounded-vs-ungrounded → deploy `claims-db` MCP server; agent answers "status of claim CLM-1234" via tool call; inspect the tool-call trace in **Tempo** → guardrail: PII input blocked (regex detector) → tokens/latency dashboard → push the agent through pipeline+GitOps ("AI apps are apps"). Llama Stack UI / MaaS console = single-path product UI.

**Demo arc (§M23):** grounded-agent-with-tools + guardrail block, ~15 min; pairs with M22.

**Timing (90–120 min):** landscape + agent anatomy ~20 · chat-via-MaaS ~10 · RAG ~20 · MCP tool call + trace ~20 · guardrail block ~15 · observe + ship-through-golden-path ~15 · wrap/when-not-to-use ~10.

### Relevant absolute paths
- Spec §M23: `Project-Shared/instructions/02-MODULE-SPECS.md`
- ADR to refresh: `docs/adr/0004-m22-shared-llama-stack-maas.md`
- MaaS-token pattern to reuse: `gitops/entry-states/m06/templates/maas-credentials.yaml`
- AI stack + Lightspeed wiring: `platform-portfolio/stacks/ai-assist/` · `platform-portfolio/components/openshift-lightspeed/`
- Apps to create: `apps/` (`parasol-agent`, `mcp-servers/` — see `apps/README.md`)
- versions.yaml (gap): `versions.yaml` (`rhoai`, `lightspeed`; add `llama_stack`/`maas`/`guardrails`)
- Field/MaaS provisioning: `docs/research/field-sourced-content-note.md`
- Mines: `OldContent/repos/agentops-in-prod-showroom/` · `OldContent/repos/parasol-insurance/`
- Format templates: `docs/research/m14-build-note.md`, `m18-build-note.md`, `m20-build-note.md`

Sources:
- RHOAI 3.4 Working with Llama Stack — https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_with_llama_stack/deploying-llama-stack-server_rag
- RHOAI 3.4 Release notes (Llama Stack 0.6.0.1+rhai0, Responses API Dev Preview, Connectors) — https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/release_notes/new-features-and-enhancements_relnotes
- Automate AI agents with the Responses API in Llama Stack — https://developers.redhat.com/articles/2026/03/09/automate-ai-agents-responses-api-llama-stack
- Ensuring AI safety with guardrails (FMS Orchestrator, regex detectors) — https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/enabling_ai_safety_with_guardrails/using-guardrails-for-ai-safety_safety
- Getting Started with GuardrailsOrchestrator / trustyai_fms — https://trustyai.org/docs/main/gorch-tutorial · https://trustyai.org/docs/main/trustyai-fms-lls-tutorial
- Scaling enterprise AI: MaaS with OpenShift AI 3.4 (GA) — https://www.redhat.com/en/blog/scaling-enterprise-ai-delivering-models-service-openshift-ai-34
- Govern LLM access with Models-as-a-Service — https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/govern_llm_access_with_models-as-a-service/use-models-as-a-service_maas
- Protecting enterprise AI: managing API keys in MaaS — https://www.redhat.com/en/blog/protecting-enterprise-ai-how-manage-api-keys-models-service-maas
- Quarkus LangChain4j MCP integration — https://docs.quarkiverse.io/quarkus-langchain4j/dev/mcp.html · extension v1.10.0 https://quarkus.io/extensions/io.quarkiverse.langchain4j/quarkus-langchain4j-mcp/
- Live cluster `ocp-ws-revamped` (read-only): `oc get packagemanifest rhods-operator/lightspeed-operator`, `oc get olsconfig cluster`, `oc get crd`, `oc get secret credentials -n openshift-lightspeed` (2026-07-12)
