#!/usr/bin/env bash
# shellcheck disable=SC2034  # USER_NAME/ENTRY_ONLY/SOLVE_MODE are consumed by the sourcing verify script
# Shared helpers for per-module verify scripts (tools/verify/mNN.sh).
# Contract: each script takes --user U (default user1) and optional --entry-only,
# checks ENTRY state (what `ws start` materializes) and, unless --entry-only,
# END state (what a completed lab looks like); exits 0 only if all checks pass.
# Output style: one line per check, ✅/❌ + fix hint. CI runs these standalone.

VERIFY_PASS=0
VERIFY_FAIL=0
# Third outcome, and it is NOT a pass: a check the caller could not evaluate (see warn()). Counted so
# verify_summary can say so — for eleven of these scripts the summary used to swallow it entirely.
VERIFY_SKIP=0

# ── the API's answer, classified — do not swallow errors with `2>/dev/null` ────────────────────────
#
# `oc get … 2>/dev/null` cannot tell "the object you were told to create is not there" (a real,
# gradeable ❌) from "the cluster did not answer" (throttling, an apiserver blip, an expired token, a
# network hiccup — not the attendee's lab, and not gradeable at all). Both come back as an empty
# string, so the attendee is told their correct work is wrong. The project's rule is that a false ❌
# destroys attendee trust in every other ✅, so this is a trust bug, not a cosmetic one.
#
# oc_read is the third-outcome primitive: it runs one `oc` read, keeps stdout and stderr apart, and
# says which KIND of answer came back. Same shape jobs-batch-kueue's ClusterQueue guard and
# gitops-fundamentals' Argo access-plane guard already use by hand — this is that pattern, once.
#
# Sets OC_OUT (stdout, no trailing newline) and OC_ERR (stderr, flattened to one line).
#   rc 0 → THE API ANSWERED. OC_OUT may be empty, and empty is a real answer: the object or the field
#          is genuinely absent, which must stay a ❌. NotFound is folded in here on purpose.
#   rc 1 → THE API COULD NOT BE ASKED, and VERIFY_INCONCLUSIVE is set to 1 so check() reports ⚠ SKIP
#          instead of ❌. Never a pass either — "cannot tell" is its own outcome, not optimism.
#
# CLASSIFICATION IS AN ALLOWLIST OF "COULD NOT ASK", NOT OF "ABSENT" — deliberately, and this is the
# load-bearing choice. Defaulting the unknown case to inconclusive would quietly downgrade genuine
# absences to skips the moment a message we did not foresee appeared, and a skip that should have
# been a ❌ is the same trust bug pointed the other way. So: anything not recognised as a transport,
# credential or authorization failure is treated as the server's real answer and still fails loudly.
# It also keeps `oc auth can-i`'s plain "no" (rc 1, stderr only a namespace-scope Warning) a ❌.
#
# Patterns below were captured from a live 4.20 cluster, 2026-08-01, not from memory:
#   NotFound      Error from server (NotFound): deployments.apps "x" not found            → ANSWERED
#   no such CRD   error: the server doesn't have a resource type "widgets"                → ANSWERED
#                 (the operator is not installed — a real platform failure worth a ❌)
#   refused       The connection to the server 127.0.0.1:59999 was refused - did you …    → could not ask
#   expired token error: You must be logged in to the server (Unauthorized)               → could not ask
#                 couldn't get current server API group list: the server has asked for …  → could not ask
#   timeout       Unable to connect to the server: net/http: request canceled … Client.Timeout
#                 … context deadline exceeded                                             → could not ask
#   forbidden     Error from server (Forbidden): … cannot list resource … at the cluster scope
#                 (rule 10: not this identity's check to run — see tools/verify/README.md)
VERIFY_INCONCLUSIVE=0
OC_OUT=""
OC_ERR=""
oc_read() {  # oc_read <oc args…> → OC_OUT/OC_ERR; rc 0 = oc succeeded, 1 = real NO, 2 = could not ask
  local errfile rc=0
  # One short-lived file per call rather than a process-wide one plus a trap: verify scripts exit
  # through verify_summary's `exit`, and an EXIT trap installed here would fight any the script sets.
  errfile="$(mktemp "${TMPDIR:-/tmp}/ogsr-verify.XXXXXX")" || {
    OC_OUT=""; OC_ERR="could not create a temp file for stderr"; VERIFY_INCONCLUSIVE=1; return 2
  }
  # `|| rc=$?` and not a bare assignment: under the callers' `set -e` a failing command substitution
  # in an assignment kills the script outright, which is the one thing this helper must never do.
  OC_OUT="$(oc "$@" 2>"$errfile")" || rc=$?
  # An attendee has to be able to READ this. client-go prefixes five identical klog "Unhandled Error"
  # lines (E0801 02:00:31.256518 … memcache.go:265) to every connection failure, and dumping them raw
  # buried the one human-readable sentence oc prints last under ~1.5 kB of noise. Drop the klog lines,
  # flatten what remains, cap it: the classification below still reads the FULL text from the file's
  # own content via this same variable, and every pattern it matches survives the trim.
  OC_ERR="$(sed -e '/^[EWIF][0-9]\{4\} [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/d' "$errfile" | tr '\n' ' ' | tr -s ' ')"
  # Nothing but klog noise (some failures print only that) → fall back to the raw text so the
  # classification is never handed an empty string it would misread as "the server's real answer".
  [[ -n "${OC_ERR// /}" ]] || OC_ERR="$(tr '\n' ' ' <"$errfile" | tr -s ' ')"
  OC_ERR="${OC_ERR#"${OC_ERR%%[![:space:]]*}"}"   # trim leading space
  rm -f "$errfile"
  if (( rc == 0 )); then
    return 0
  fi
  # rc 1 vs rc 2 is the WHOLE POINT and an earlier draft got it wrong: folding NotFound into rc 0
  # made `check "PodDisruptionBudget parasol-claims exists" oc get pdb …` PASS on a namespace that had
  # no PDB at all (caught by diffing a full run against HEAD on user7, 2026-08-01). A genuine absence
  # is a real answer and must stay a ❌ — only "could not ask" may become ⚠.
  case "$OC_ERR" in
    *"(Forbidden)"*|*" is forbidden"*|\
    *"(Unauthorized)"*|*"must be logged in to the server"*|*"asked for the client to provide credentials"*|\
    *"(TooManyRequests)"*|*"(ServiceUnavailable)"*|*"(InternalError)"*|*"(ServerTimeout)"*|*"(Timeout)"*|\
    *"Unable to connect to the server"*|*"connection to the server"*|*"connection refused"*|\
    *"context deadline exceeded"*|*"Client.Timeout"*|*"i/o timeout"*|*"TLS handshake timeout"*|\
    *"no such host"*|*"connection reset by peer"*|*"network is unreachable"*|*"no route to host"*|\
    *"currently unable to handle the request"*|*"unable to retrieve the complete list of server APIs"*|\
    *"couldn't get current server API group list"*|*"etcdserver:"*|*"unexpected EOF"*|\
    *"no configuration has been provided"*|*"Missing or incomplete configuration"*)
      OC_OUT=""
      VERIFY_INCONCLUSIVE=1
      return 2
      ;;
    *)
      # NotFound, "doesn't have a resource type", and anything else not recognised as a transport or
      # credential failure: the server's real answer. Still a ❌ — unchanged from before this helper.
      OC_OUT=""
      return 1
      ;;
  esac
}

# Absence, asked safely. `! oc get … 2>/dev/null` and `[[ -z "$(oc get … 2>/dev/null)" ]]` both
# certify a clean slate from an API that never answered — the one direction this whole change must
# never take, since a wrongly-green entry check sends `ws prep` down its "already prepared" fast path.
oc_absent() {  # <oc get args…> → 0 only when the API ANSWERED and nothing is there
  local rc=0
  oc_read "$@" || rc=$?
  if (( rc == 2 )); then return 1; fi   # could not ask → ⚠ via the flag, never a certified clean slate
  if (( rc == 1 )); then return 0; fi   # NotFound → genuinely absent
  [[ -z "$OC_OUT" ]]                    # rc 0: an empty list is also genuinely absent
}

oc_present() {  # <oc get args…> → 0 only when the API ANSWERED and something is there
  oc_read "$@" || return 1
  [[ -n "$OC_OUT" ]]
}

# An oc read whose REFUSAL IS EXPECTED because a FALLBACK answers the same question — the gitea route
# read every module does before deriving the host from the ingress domain instead. Attendees cannot
# read routes in ogsr-gitea (rule 10), so that read's Forbidden is the NORMAL case and must never
# become the check's verdict; but check() consults VERIFY_INCONCLUSIVE whenever the predicate fails,
# so a raised-then-unwanted flag turns a genuinely missing thing (a real ❌) into ⚠.
#
# Added here, not worked around in the modules: tools/verify/platform-orientation.sh left its own copy
# of that read deliberately blind and reported (2026-08-01) that the missing piece was "an _lib.sh
# primitive for an oc read whose refusal is expected because a fallback answers it — an
# oc_read_optional, or a save/restore pair", because the alternative is a module script assigning the
# shared flag itself, which invents a flag-lifecycle rule in the wrong file. shellcheck says so out
# loud when you try: SC2034, the module writes the shared flag and never reads it. That warning is the
# signal, not the nuisance — this is what it was pointing at.
#
# Contract: exactly oc_read's, MINUS the third outcome. If you cannot answer the question some other
# way when this returns 1, you want oc_read, not this.
oc_read_optional() {  # <oc args…> → 0 + OC_OUT; 1 on ANY failure, VERIFY_INCONCLUSIVE left untouched
  local saved="$VERIFY_INCONCLUSIVE" rc=0
  oc_read "$@" || rc=$?
  VERIFY_INCONCLUSIVE="$saved"
  if (( rc == 0 )); then return 0; fi
  return 1
}

# ── the gitea host, once ────────────────────────────────────────────────────────────────────────
#
# Route "gitea" in namespace "ogsr-gitea" → gitea-ogsr-gitea.<ingress-domain>. Copy-pasted byte-for-
# byte (barring drift) into SEVEN tools/verify/*.sh scripts — config-multienv, build-deliver,
# devspaces-inner-loop, developer-hub-golden-paths, gitops-fundamentals, pipelines-fundamentals,
# trusted-supply-chain — the same argument as deploy_ready above, once more: seven places to get the
# same fix wrong. gitops-at-scale.sh's read_gitea_host() and platform-orientation.sh's inlined
# gitea_user_exists() were already converted to the oc_read/oc_read_optional contract; this canonical
# version follows that pattern, so collapsing the other seven onto it finishes a conversion already
# under way rather than starting a new one.
#
# GLOBAL, not echo-shaped — deliberately, for the same reason developer-hub-golden-paths'
# ingress_domain()/rhdh_host() and gitops-at-scale's read_ingress_domain() are global too: a caller
# assigning via `host="$(gitea_host)"` runs the whole body in a SUBSHELL, and the VERIFY_INCONCLUSIVE
# the ingress-domain fallback raises on a genuine outage dies with that subshell — the flag never
# reaches the caller's check(), so a real cluster blip renders as a false ❌ on the attendee's work
# instead of ⚠. Six of the seven collapsed copies called `gitea_host` exactly that way; it was
# invisible before because none of them touched oc_read at all (`2>/dev/null || true` never sets the
# flag either way), so collapsing onto oc_read/oc_read_optional without ALSO dropping the `$(...)`
# calling convention at every call site would have reintroduced the identical trap on the one read
# this whole helper battery exists to catch.
GITEA_HOST=""
gitea_host() {  # → 0 + GITEA_HOST set; 1 when the host could not be determined (flag says why)
  GITEA_HOST=""
  # oc_read_OPTIONAL, not oc_read: this route read is a best-effort SHORTCUT, and an attendee is
  # EXPECTED to be refused it (rule 10 — routes in ogsr-gitea are not theirs to read). Its refusal
  # must not become the caller's verdict, because the ingress-domain fallback below answers the same
  # question perfectly well. tools/lint/verify-oc-read-guard.sh used to exclude this fallback BY NAME
  # from its blind-read ratchet, back when every copy still used a raw `2>/dev/null`; routing through
  # oc_read_optional/oc_read here retires that exclusion's reason to exist rather than relying on it.
  if oc_read_optional get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' && [[ -n "$OC_OUT" ]]; then
    GITEA_HOST="$OC_OUT"
    return 0
  fi
  # Plain oc_read, not oc_read_optional: this IS the last resort, so if it also cannot be asked,
  # "could not determine the host" is genuinely inconclusive and must raise VERIFY_INCONCLUSIVE — what
  # keeps a real cluster outage a ⚠ instead of a false ❌ on a genuinely missing Gitea object.
  oc_read get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' || return 1
  [[ -n "$OC_OUT" ]] || return 1
  GITEA_HOST="gitea-ogsr-gitea.${OC_OUT}"
}

# ── is the cluster there at all? the fallback probe HTTP checks grade against ─────────────────────
#
# One cheap question, asked ONLY after something else already failed: did ANY apiserver answer? kube's
# `system:public-info-viewer` ClusterRole carries /healthz and is bound to system:authenticated AND
# system:unauthenticated, so an attendee can ask it — measured on cluster 2 (4.20) as user4 with
# --as/--as-group, 2026-08-01, not recalled. --request-timeout caps it: this runs on a path that is
# already slow, and a probe that hangs turns one bad check into a bad suite.
#
# ONE VERDICT PER RUN, cached. A verify run is seconds long; re-probing per failed check would pay the
# timeout once per check for an answer that cannot meaningfully have changed in between.
#
# NO SIDE EFFECTS on the caller's classification state. It drives oc_read — so the transport-failure
# vocabulary stays in ONE place, the audited one — then puts OC_OUT/OC_ERR/VERIFY_INCONCLUSIVE back
# exactly as it found them. http_read raises the flag itself, deliberately and visibly, so that a
# reader can see where the ⚠ comes from instead of it leaking out of a helper.
#
# REACHABLE MEANS "AN APISERVER PRODUCED THIS", not "the read succeeded" — Forbidden, Unauthorized and
# NotFound all prove the network path this probe exists to test. oc_read files Forbidden/Unauthorized
# under "could not ask" because it is grading a READ; here the only question is whether the cluster is
# there, and a 403 is emphatic proof that it is.
#
# THE DEFAULT IS "DOWN", the opposite of oc_read's default, and deliberately so. This probe's only job
# is to LICENSE a ❌; anything it cannot recognise as an apiserver's own voice — `oc` not on PATH, no
# kubeconfig, DNS, refused, timeout — must not license one. Erring here costs an under-reported ❌
# (a ⚠ that says "could not ask"); erring the other way costs the false ❌ this whole design exists to
# delete, on an attendee who did the lab correctly.
VERIFY_API_PROBE=""   # "" not asked yet · "up" · "down" — one verdict per run
VERIFY_API_ERR=""
cluster_api_reachable() {  # → 0 an apiserver answered something, 1 nothing did
  if [[ -n "$VERIFY_API_PROBE" ]]; then
    if [[ "$VERIFY_API_PROBE" == "up" ]]; then return 0; fi
    return 1
  fi
  # oc_read_optional keeps the flag out of it; OC_OUT/OC_ERR are saved here because the classification
  # below has to READ OC_ERR before putting the caller's value back.
  local saved_out="$OC_OUT" saved_err="$OC_ERR" rc=0
  oc_read_optional get --raw /healthz --request-timeout=5s || rc=$?
  VERIFY_API_PROBE="up"
  VERIFY_API_ERR=""
  if (( rc != 0 )); then
    case "$OC_ERR" in
      *"Error from server"*|*"(Forbidden)"*|*" is forbidden"*|\
      *"(Unauthorized)"*|*"must be logged in to the server"*|*"(NotFound)"*)
        : ;;   # the apiserver's own voice — the cluster is there
      *)
        VERIFY_API_PROBE="down"
        VERIFY_API_ERR="${OC_ERR:0:120}"
        ;;
    esac
  fi
  OC_OUT="$saved_out"; OC_ERR="$saved_err"
  if [[ "$VERIFY_API_PROBE" == "up" ]]; then return 0; fi
  return 1
}

# ── the app's answer, classified — oc_read's three outcomes, over HTTP ────────────────────────────
#
# oc_read gave cluster READS three outcomes. HTTP probes still had two, and the gap is the same trust
# bug in a different costume: `code="$(curl … || true)"; [[ "$code" == "200" ]]` prints the identical
# ❌ for "the app returned 503" (the attendee's lab, gradeable, and a thing these labs deliberately
# teach) and for "there is no route from here to this cluster" (hotel wifi, a dead RHDP environment —
# not the attendee's lab and not gradeable at all).
#
# THE MECHANISM IS A SECOND PROBE, not a longer list of curl exit codes (owner's design, 2026-08-01:
# "do just another access check if you can't access the app? try to access cluster API and see if only
# app or the whole cluster"). When the HTTP probe fails at the transport layer, ask the cluster API one
# cheap question. API answers → the path from here to the cluster works, so this URL specifically is
# broken → a real ❌, graded exactly as before. API silent too → nothing here can be graded → ⚠,
# through the same VERIFY_INCONCLUSIVE flag check() already reads for oc_read.
#
# WHICH CURL EXITS ASK THE SECOND QUESTION. Two families, and the split is where an HTTP response
# either did or did not arrive:
#
#   AN HTTP RESPONSE ARRIVED → the server answered, that answer IS the verdict, and the cluster API is
#   never consulted. Exit 0 covers every status code, because this helper does not pass -f: a 404 or a
#   503 is a SUCCESSFUL probe with a telling HTTP_CODE. "The Route serves 503 because the Service has
#   no endpoints" is a real failure a lab teaches and must stay ❌. Exit 22 is the same event seen by a
#   caller that does pass -f.
#
#   NO HTTP RESPONSE ARRIVED → could be the app, could be the environment, and curl alone cannot tell.
#   These consult the probe:
#     5  proxy unresolvable   6  host unresolvable — DNS. Note a MISSING Route does not present this
#        way: *.apps is a wildcard, so an absent Route still resolves and the router answers 503, i.e.
#        exit 0 above. A code-6 here means the whole apps domain is unresolvable, which takes the
#        cluster's own api endpoint (same parent domain) with it — exactly the case that must not grade.
#     7  connect refused/failed   28 timed out   35 TLS connect failed
#     16/92 HTTP/2 framing   18 partial transfer   52 empty reply   55 send failed   56 recv failed
#     60/91 certificate rejected — we pass -k, so in practice a proxy MITM, not the app.
#   The list is deliberately generous because it is NOT the decision: the probe is. A generous list
#   still yields ❌ on every one of these whenever the cluster API answers.
#
# EVERYTHING ELSE IS A REAL ANSWER — the same load-bearing default as oc_read, pointed the same way.
# Exit 3 (malformed URL) and 2/4 (curl misbuilt or misused) are OUR bug: deterministic, not fixed by
# retrying, and a ⚠ telling the attendee "re-run in a moment" would hide them forever. An unlisted
# future exit code fails loudly rather than being quietly downgraded to a skip.
#
# KNOWN LIMIT, stated rather than hidden: the probe proves the APISERVER is reachable, which is not the
# same path as the ROUTER. A cluster whose apiserver is healthy while its ingress is dead still grades
# app checks ❌. That is the owner's rule taken literally, and it is the safe half of the ambiguity —
# a router outage is a genuine platform failure worth a red line, where "no route to the cluster at
# all" is not the attendee's lab. Same for a URL that is not on this cluster (an upstream registry):
# the probe cannot speak for it.
HTTP_CODE=""
HTTP_OUT=""
http_read() {  # http_read <url> [curl args…] → HTTP_CODE/HTTP_OUT; rc 0 = answered, 1 = real NO, 2 = could not ask
  local url="$1"; shift
  local bodyfile errfile rc=0 curl_err why
  HTTP_CODE=""
  HTTP_OUT=""
  # Cleared like oc_read clears it, and for the same reason: OC_ERR must describe THIS probe or
  # nothing. A stale reason surviving a successful call is a foot-gun for whoever reads it next.
  OC_ERR=""
  # One short-lived pair per call, for the same reason oc_read does it that way: verify scripts exit
  # through verify_summary's `exit`, and an EXIT trap installed here would fight any the script sets.
  bodyfile="$(mktemp "${TMPDIR:-/tmp}/ogsr-verify-body.XXXXXX")" || {
    OC_ERR="could not create a temp file for the response body"; VERIFY_INCONCLUSIVE=1; return 2
  }
  errfile="$(mktemp "${TMPDIR:-/tmp}/ogsr-verify-curl.XXXXXX")" || {
    rm -f "$bodyfile"
    OC_ERR="could not create a temp file for curl's stderr"; VERIFY_INCONCLUSIVE=1; return 2
  }
  # -sS: no progress meter, but DO keep curl's one-line reason on stderr — it is what the ⚠ quotes.
  # -k: every route probed here is served by the cluster's own edge cert. --max-time comes BEFORE
  # "$@" so a caller can override it simply by passing its own (curl honours the last occurrence).
  # `|| rc=$?` and not a bare assignment: under the callers' `set -e` a failing command substitution
  # in an assignment kills the script outright, which is the one thing this helper must never do.
  HTTP_CODE="$(curl -sS -k -o "$bodyfile" -w '%{http_code}' --max-time 15 "$@" "$url" 2>"$errfile")" || rc=$?
  # Bodies probed by this suite are small (health endpoints, Gitea API JSON, a two-byte range request).
  # A caller that must not slurp a large one passes its own -r / --max-filesize, as cli_download_ready
  # does; NUL bytes in a binary body are dropped by the command substitution, which no caller greps for.
  HTTP_OUT="$(cat "$bodyfile")"
  curl_err="$(tr '\n' ' ' <"$errfile" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  rm -f "$bodyfile" "$errfile"
  if (( rc == 0 )); then
    return 0
  fi
  # curl wrote "000" into HTTP_CODE for a probe that never got a response; blank both so a caller that
  # forgets to check the rc gets an obviously-empty value rather than a plausible-looking one.
  HTTP_CODE=""
  HTTP_OUT=""
  why="curl exit ${rc}${curl_err:+ — ${curl_err}}"
  case "$rc" in
    5|6|7|16|18|28|35|52|55|56|60|91|92)
      if cluster_api_reachable; then
        OC_ERR="${why} (the cluster API answered, so this is ${url}, not the cluster)"
        return 1
      fi
      # ⚠ and ONLY ⚠: check() prints the skip line and returns 0, so the call site's own `|| hint …`
      # — which would tell the attendee to redo work they may well have done correctly — never fires.
      OC_ERR="${url} could not be reached (${why}) and neither could the cluster API (${VERIFY_API_ERR})"
      VERIFY_INCONCLUSIVE=1
      return 2
      ;;
    *)
      OC_ERR="$why"
      return 1
      ;;
  esac
}

check() {  # check "<description>" <command...>  — pass/fail/SKIP one assertion
  local desc="$1"; shift
  local rc=0
  # Cleared per check so the flag can only describe THIS assertion; only oc_read ever raises it, so a
  # predicate that never touches oc_read behaves exactly as it did before this helper existed.
  VERIFY_INCONCLUSIVE=0
  if [[ "${1:-}" == "oc" ]]; then
    # Every `check "…" oc get …` call site in this suite (103 of them, counted 2026-08-01) gets the
    # three-outcome treatment with no change at the call site: the classification belongs to the tool,
    # not to 103 hand-written repetitions of it.
    shift
    oc_read "$@" || rc=$?
  else
    "$@" >/dev/null 2>&1 || rc=$?
  fi
  if (( rc == 0 )); then
    echo "✅ ${desc}"
    VERIFY_PASS=$((VERIFY_PASS+1))
    return 0
  fi
  # The FLAG, not the rc, carries the classification: predicates return whatever they like (curl's
  # exit codes reach here too), and only oc_read can raise the flag. rc alone would collide.
  if (( VERIFY_INCONCLUSIVE == 1 )); then
    # Truncated HERE, not in oc_read: the classification must see the whole message, the attendee
    # only needs the gist. One line, not a paragraph — this sits in a list of ✅s.
    local why="${OC_ERR:0:160}"
    [[ "${#OC_ERR}" -le 160 ]] || why="${why}…"
    # "Refused to answer" and "could not answer" are different problems with different next steps, and
    # telling an attendee to retry an RBAC denial wastes their time. Split the message accordingly.
    case "$OC_ERR" in
      *"(Forbidden)"*|*" is forbidden"*)
        warn "${desc} — not readable as this identity${why:+ (${why})}"
        hint "not yours to fix and not graded: this check asks for something your account may not read, so it has no verdict here. Run it where it can be answered — your own cockpit terminal for your own namespaces, or an instructor/CI run for cluster-wide objects"
        ;;
      *"and neither could the cluster API"*)
        # http_read's ⚠: the app URL did not answer AND the fallback probe found no apiserver either.
        # Named separately from the oc branch below so the line says what was actually attempted —
        # the attendee's next step is the same, but "the app did not answer" is the honest wording.
        warn "${desc} — the app did not answer and neither did the cluster API${why:+ (${why})}"
        hint "not your lab, and not graded: nothing on this cluster could be reached, so this check has no verdict. Re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
        ;;
      *)
        warn "${desc} — the cluster API did not answer${why:+ (${why})}"
        hint "not your lab, and not graded: the cluster could not be asked, so this check has no verdict. Re-run the same ws verify in a moment; if it keeps happening, check your session with 'oc whoami' and tell your instructor"
        ;;
    esac
    # Returns 0 so the call site's own `|| hint \"…\"` — which tells the attendee to redo work they
    # may well have done correctly — does NOT fire. The ⚠ line above is the whole verdict.
    return 0
  fi
  echo "❌ ${desc}"
  VERIFY_FAIL=$((VERIFY_FAIL+1))
  return 1
}

hint() { echo "   ↳ fix: $*"; }

# A ConfigMap whose values are written by an Argo Sync hook rather than rendered by the chart —
# maas-config / maas-config-env in the AI entry states — EXISTS from the moment the chart applies, so
# `oc get cm` passing is no longer evidence that anything wired it up. The chart deliberately renders
# metadata only (the model comes from the cluster's MaaS Secret, not from git), which means an existence
# check would go green on a ConfigMap the hook never filled. Assert the key the workloads actually read.
cm_key_set() {  # namespace configmap key → 0 when that key exists and is non-empty
  oc_read get configmap "$2" -n "$1" -o jsonpath="{.data.$3}" || return 1
  [[ -n "$OC_OUT" ]]
}

# ── hoisted from the modules ──────────────────────────────────────────────────────────────────────
# deploy_ready was copy-pasted, byte-for-byte apart from its argument style, into NINETEEN verify
# scripts backing FIFTY-ONE call sites (counted 2026-08-01) — every copy swallowing the API error the
# same way. Nineteen places to get the same fix wrong is the argument for it living here once.
# Both historical call styles are supported so no call site had to change: scripts that set a single
# NS pass just the name, the rest pass name + namespace explicitly.
deploy_ready() {  # <deployment> [namespace] → at least one ready replica
  oc_read get deploy "$1" -n "${2:-${NS:-}}" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" -ge 1 ]]
}

# >=, never ==: several labs have the attendee deliberately exceed the overlay's canonical replica
# count (config-multienv's prod Challenge, gitops-fundamentals Exercise D), and an exact match would
# false-fail a correctly-completed lab.
deploy_ready_min() {  # <deployment> <namespace> <n> → at least n ready replicas
  oc_read get deploy "$1" -n "$2" -o jsonpath='{.status.readyReplicas}' || return 1
  [[ -n "$OC_OUT" && "$OC_OUT" -ge "$3" ]]
}

# INCONCLUSIVE, never a failure — for a check the CALLER cannot evaluate (no impersonation rights, an
# in-cluster-only endpoint on an off-cluster run). Deliberately does NOT touch the pass/FAIL counters:
# a false ❌ destroys attendee trust in every other ✅ (tools/verify/README.md, contract).
# It DOES count as a skip, because "not a failure" is not the same as "graded and fine" — see
# verify_summary. Follow every warn with a hint saying WHERE the check can be answered.
warn() { echo "⚠ $* — SKIPPED (not a failure)"; VERIFY_SKIP=$((VERIFY_SKIP+1)); }

# Neutral note (skipped/context lines) — matches ws's own info style so smoke output is unchanged
# when a verify script shadows it. Standalone verify scripts (multi-tenancy-workload-security/networking-dev-devops) rely on this being defined.
info() { echo "▶ $*"; }

# THREE outcomes in, three outcomes out. The banner used to know only pass/fail, so a run in which
# every GRADED outcome was skipped still ended "✅ all 7 checks passed", exit 0 — false completeness
# in 11 of 26 scripts (audit 2026-07-31; worst case multi-tenancy-workload-security, where all six
# end-state RBAC outcomes — the entire lesson — sit behind one impersonation guard). The fix is here,
# not in warn(): a check that genuinely cannot run must still never print ❌.
#
# EXIT CODE, deliberately: skipped-but-nothing-failed exits 0 by DEFAULT. `ws prep` reads
# `<script> --entry-only`'s rc as a boolean "is this world already prepared?" (tools/ws/ws cmd_prep),
# and a non-zero rc there tells the attendee their environment is broken and offers to WIPE it — a
# destructive false alarm on a healthy world. `ws smoke` reads the same rc as a G1 ❌. So the BANNER
# carries the signal for humans, and automation that must fail closed opts in with VERIFY_STRICT=1
# and gets rc 3 — distinct from 1 (a check actually FAILED) and 2 (usage error, parse_verify_args).
verify_summary() {  # call at end of every script
  echo
  local graded=$((VERIFY_PASS+VERIFY_FAIL))
  if (( VERIFY_FAIL > 0 )); then
    if (( VERIFY_SKIP > 0 )); then
      echo "❌ ${VERIFY_FAIL} of ${graded} checks failed · ⚠ ${VERIFY_SKIP} SKIPPED (not graded)"
    else
      echo "❌ ${VERIFY_FAIL} of ${graded} checks failed"
    fi
    exit 1
  fi
  if (( VERIFY_SKIP > 0 )); then
    echo "⚠ ${VERIFY_PASS} passed · ${VERIFY_SKIP} SKIPPED (not graded) — this run did NOT fully verify the lab"
    echo "   ↳ each ⚠ line above says where its check can be answered; re-run there for a complete result"
    # `if`, not `[[ … ]] && exit 3`: under the callers' `set -e` a false one-liner would return 1 from
    # this function and kill the script — turning a skip into the exit 1 the whole design avoids.
    if [[ "${VERIFY_STRICT:-0}" == "1" ]]; then
      exit 3
    fi
    exit 0
  fi
  echo "✅ all ${VERIFY_PASS} checks passed"
  exit 0
}

parse_verify_args() {  # sets USER_NAME, ENTRY_ONLY, SOLVE_MODE from "$@"
  USER_NAME="user1"
  ENTRY_ONLY="false"
  # SOLVE_MODE=true ONLY when validating a `ws solve` result (ws verify <m> --solve, or CI). A script may
  # then hard-assert its ws-solve-<module> marker. A plain `ws verify` — the attendee's own closing verify
  # after doing the lab BY HAND — leaves SOLVE_MODE=false, so a marker that only `ws solve` stamps must NOT
  # be asserted (the lab's real OUTCOME checks carry the proof; a false ❌ on a correctly-completed lab
  # destroys trust in every other ✅).
  SOLVE_MODE="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) USER_NAME="$2"; shift 2;;
      --entry-only) ENTRY_ONLY="true"; shift;;
      --solve) SOLVE_MODE="true"; shift;;
      *) echo "unknown arg: $1" >&2; exit 2;;
    esac
  done
}
