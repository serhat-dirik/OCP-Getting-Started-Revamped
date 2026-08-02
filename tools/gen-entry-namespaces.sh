#!/usr/bin/env bash
#
# gen-entry-namespaces.sh — materialize each entry-state chart's own copy of the per-user
# Namespace/ResourceQuota/LimitRange/RoleBinding templates, from the canonical source
# gitops/user-namespace/templates/ (01-ARCHITECTURE §Entry-state system, §Cluster profiles/RBAC).
#
# WHY THIS EXISTS. An attendee cannot create a Namespace or a ResourceQuota (probed on cluster
# 2026-08-02 as user1, both `namespaces` create and `resourcequotas` create come back Forbidden),
# and the admission policy `ogsr-attendee-entry-app-guard` only permits an attendee to create an
# Application named `entry-<module>-<user>` sourced from gitops/entry-states/. So each entry chart
# must render its own namespaces — `ws prep`, which runs AS the attendee, can never apply them, and
# Helm cannot read files outside its own chart root, so gitops/user-namespace/templates/ cannot be
# `.Files.Get` by an entry chart directly. The fix is the same shape as versions.yaml ->
# tools/gen-attributes.sh: one canonical source, a generator that reproduces the per-chart copy
# byte-for-byte, and a --check mode CI runs as a drift gate.
#
# THE TRANSFORMATION (canonical gitops/user-namespace/templates/{namespace,limits,rbac}.yaml ->
# one gitops/entry-states/<slug>/templates/ns-user-namespaces.yaml per chart):
#   1. The three source files are concatenated in order (namespace.yaml, limits.yaml, rbac.yaml),
#      each preceded by a `{{/* ---- from user-namespace/templates/<file> ---- */}}` marker, with a
#      blank line between sections.
#   2. Each source file's own leading `{{/* ... */}}` header comment is kept verbatim.
#   3. `{{- include "user-namespace.assertInputs" . -}}` and `{{- $user := .Values.user -}}` are
#      dropped from each section — the copy defines `$user` ONCE in its own file-level header
#      instead (see below), and does not need assertInputs: suffixes come from ws-meta.yaml, which
#      is a chart file, not a Values parameter, so there's nothing for assertInputs to validate.
#   4. `{{- range $raw := splitList "," .Values.suffixes }}` becomes `{{- range $raw := $suffixes }}`
#      — the copy iterates the suffix list read from its own ws-meta.yaml, not a Helm parameter.
#   5. In namespace.yaml's section ONLY, the bare
#        argocd.argoproj.io/managed-by: {{ $.Values.studentArgoNamespace }}
#      becomes a `required` call. A null studentArgoNamespace silently stops the student Argo
#      operator creating its RoleBindings (SEV1 2026-07-18) — the canonical chart's own
#      assertInputs never validated this value (it isn't a `suffix`), so the copy adds a fail-loud
#      guard where the source has none.
#   6. A file-level header is prepended: `.Files.Get "ws-meta.yaml"` for `$suffixes` (fail loud if
#      the module's `namespaces:` list is missing/empty — a silent empty render here would be worse
#      than an error, per user-namespace.assertInputs' own rationale), then `$user := .Values.user`.
#   7. The ENTIRE render (the header's variable/fail block plus all 3 sections) is wrapped in
#      `{{- if .Values.manageNamespaces }} ... {{- end }}`, gated OFF by a `manageNamespaces: false`
#      default this generator also writes into each chart's values.yaml. WHY: gitops/workshop-config
#      still creates all 13 per-user namespaces eagerly today (verified live 2026-08-02: `user4-dev`
#      carries tracking-id `workshop-config:/Namespace:openshift-gitops/user4-dev`, and the
#      workshop-config Application runs `prune: true, selfHeal: true`). If an entry chart ALSO
#      rendered that Namespace while workshop-config still owns it, two Applications would fight
#      over the same object — our sync-wave/sync-options annotations stripped by workshop-config's
#      selfHeal and re-added by the entry app, forever. So this feature is inert (renders ZERO
#      objects) until `manageNamespaces` flips to true, which is a DELIBERATE migration step that
#      must land in the SAME change as removing workshop-config's per-user namespace rendering,
#      never before.
#
# The companion file templates/_ns-helpers.tpl is a BYTE-IDENTICAL copy of
# gitops/user-namespace/templates/_helpers.tpl (including the now-unused
# user-namespace.assertInputs define — harmless, it is simply never called from the copy).
#
# `manageNamespaces: false` is spliced into each chart's values.yaml between marker comments (same
# splice idiom as tools/gen-module-slugs.sh's moduleSlugs block) so re-running this generator never
# duplicates it and never disturbs the rest of a hand-maintained values.yaml.
#
# Idempotent: same canonical source -> byte-identical output for every chart. CI runs `--check` as
# a drift gate; tools/lint/copy-drift-guard.py separately holds the copies in lockstep for anyone
# who edits a canonical or copy file directly without running this generator.
#
# Usage:  tools/gen-entry-namespaces.sh          # regenerate every entry-state chart's copy
#         tools/gen-entry-namespaces.sh --check  # exit 1 if any committed copy is stale
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
canonical_dir="${repo_root}/gitops/user-namespace/templates"
entry_states_dir="${repo_root}/gitops/entry-states"

for f in namespace.yaml limits.yaml rbac.yaml _helpers.tpl; do
  if [ ! -f "${canonical_dir}/${f}" ]; then
    echo "❌ canonical source ${canonical_dir#"${repo_root}/"}/${f} not found." >&2
    exit 1
  fi
done

# The per-section transform (rules 2-5 above), as an awk program written to a temp file so the
# quoting stays sane — the rules replace whole lines verbatim, never pattern-match a fragment.
awk_script="$(mktemp)"
trap 'rm -f "$awk_script" "${tmp_ns_file:-}" "${tmp_helpers_file:-}" "${tmp_values_block:-}" "${spliced_values:-}"' EXIT
cat > "$awk_script" <<'AWK'
BEGIN { in_header = 1 }
{
  line = $0
  if (in_header) {
    print line
    if (line == "*/}}") { in_header = 0 }
    next
  }
  if (line == "{{- include \"user-namespace.assertInputs\" . -}}") { next }
  if (line == "{{- $user := .Values.user -}}") { next }
  if (line == "{{- range $raw := splitList \",\" .Values.suffixes }}") {
    print "{{- range $raw := $suffixes }}"
    next
  }
  if (line == "    argocd.argoproj.io/managed-by: {{ $.Values.studentArgoNamespace }}") {
    print "    argocd.argoproj.io/managed-by: {{ required \"studentArgoNamespace is required (ws passes it; see tools/ws/ws render_app) — a null here silently stops the student Argo operator creating its RoleBindings, SEV1 2026-07-18\" $.Values.studentArgoNamespace }}"
    next
  }
  print line
}
AWK

# Render the full ns-user-namespaces.yaml body to stdout (rule 6's header + the 3 transformed
# sections, rule 1's markers and blank-line separators).
render_ns_user_namespaces() {
  cat <<'HDR'
{{/*
  GENERATED — do not hand-edit. Canonical source: gitops/user-namespace/templates/.
  Regenerate with tools/gen-entry-namespaces.sh; tools/lint/copy-drift-guard.py holds the copies
  in lockstep, so an edit here without one there fails CI.

  WHY EACH ENTRY CHART CARRIES THIS. Namespaces must exist before this module's objects land in
  them, and an attendee CANNOT create one: probed on cluster 2026-08-02 as user1, both
  `namespaces` create and `resourcequotas` create come back Forbidden. So `ws prep`, which runs AS
  the attendee, can never apply these — Argo has to, and the only Application an attendee is
  permitted to create is `entry-<module>-<user>` sourced from gitops/entry-states/ (enforced by
  ValidatingAdmissionPolicy ogsr-attendee-entry-app-guard). That makes the entry chart itself the
  one place these can legally come from.

  The suffix list is read from this chart's OWN ws-meta.yaml `namespaces:` key rather than passed
  in, so there is exactly one source of truth per module and `ws` needs no new parameter.

  GATED behind manageNamespaces (values.yaml, default false): gitops/workshop-config still creates
  all 13 per-user namespaces eagerly today, and rendering the same Namespace from two Applications
  at once would fight over ownership (see values.yaml's comment on the flag). Flipping it to true
  is a deliberate migration step, not a per-chart decision.
*/}}
{{- if .Values.manageNamespaces }}
{{- $meta := .Files.Get "ws-meta.yaml" | fromYaml -}}
{{- $suffixes := $meta.namespaces | default (list) -}}
{{- if not $suffixes -}}
{{- fail (printf "%s/ws-meta.yaml has no `namespaces:` list — ws prep cannot know which namespaces to create, and the module would materialize into namespaces that may not exist" .Chart.Name) -}}
{{- end -}}
{{- $user := .Values.user -}}

HDR
  local first=1
  local f
  for f in namespace.yaml limits.yaml rbac.yaml; do
    if [ "$first" -eq 0 ]; then printf '\n'; fi
    first=0
    printf '{{/* ---- from user-namespace/templates/%s ---- */}}\n' "$f"
    awk -f "$awk_script" "${canonical_dir}/${f}"
  done
  printf '{{- end }}\n'
}

tmp_ns_file="$(mktemp)"
render_ns_user_namespaces > "$tmp_ns_file"
# _ns-helpers.tpl is a byte copy of the canonical _helpers.tpl (rule above) — copied into ITS OWN
# temp file, never pointed at the canonical path directly: the EXIT trap below deletes every
# tmp_*_file it's holding, and the canonical source must never be one of them.
tmp_helpers_file="$(mktemp)"
cp "${canonical_dir}/_helpers.tpl" "$tmp_helpers_file"

# Marker lines fencing the manageNamespaces block spliced into each chart's values.yaml — same
# splice idiom as tools/gen-module-slugs.sh's moduleSlugs block, so re-running this generator
# replaces exactly its own block and leaves the rest of a hand-maintained values.yaml untouched.
values_begin_marker="# BEGIN gen-entry-namespaces manageNamespaces — GENERATED by tools/gen-entry-namespaces.sh, DO NOT EDIT"
values_end_marker="# END gen-entry-namespaces manageNamespaces"

tmp_values_block="$(mktemp)"
cat > "$tmp_values_block" <<VALUES_BLOCK
${values_begin_marker}
# This chart's own Namespace/ResourceQuota/LimitRange/RoleBinding render
# (templates/ns-user-namespaces.yaml) is a no-op while this is false. gitops/workshop-config still
# creates all 13 per-user namespaces eagerly today (verified live 2026-08-02: user4-dev carries
# tracking-id workshop-config:/Namespace:openshift-gitops/user4-dev, and the workshop-config
# Application runs prune=true/selfHeal=true) — if this chart ALSO rendered the same Namespace while
# workshop-config still owns it, two Applications would fight over the same object (this chart's
# sync-wave/sync-options annotations stripped by workshop-config's selfHeal, re-added by this
# chart, forever). Flipping this to true is a DELIBERATE migration step that MUST land in the SAME
# change as removing workshop-config's per-user namespace rendering, never before.
manageNamespaces: false
${values_end_marker}
VALUES_BLOCK

# Splice tmp_values_block into a chart's values.yaml: replace an existing marked block in place, or
# append it at EOF the first time (no markers yet). Everything outside the markers passes through
# untouched. Writes the spliced result to stdout.
splice_values_block() {
  local values_file="$1"
  awk -v blockfile="$tmp_values_block" -v beginm="$values_begin_marker" -v endm="$values_end_marker" '
    BEGIN {
      block=""; while ((getline l < blockfile) > 0) block = block l "\n"; close(blockfile)
      sub(/\n$/, "", block)
      found=0
    }
    index($0, beginm) == 1 { inblock=1; found=1; print block; next }
    index($0, endm)   == 1 { inblock=0; next }
    inblock { next }
    { print }
    END { if (!found) { print ""; print block } }
  ' "$values_file"
}

check_mode=0
if [ "${1:-}" = "--check" ]; then
  check_mode=1
fi

charts=()
while IFS= read -r d; do
  charts+=("$d")
done < <(find "$entry_states_dir" -mindepth 1 -maxdepth 1 -type d | sort)

if [ "${#charts[@]}" -eq 0 ]; then
  echo "❌ no chart directories found under ${entry_states_dir#"${repo_root}/"}." >&2
  exit 1
fi

stale=()
written=0
for chart_dir in "${charts[@]}"; do
  slug="$(basename "$chart_dir")"
  templates_dir="${chart_dir}/templates"
  ns_out="${templates_dir}/ns-user-namespaces.yaml"
  helpers_out="${templates_dir}/_ns-helpers.tpl"
  values_out="${chart_dir}/values.yaml"

  if [ ! -f "$values_out" ]; then
    echo "❌ ${values_out#"${repo_root}/"} not found — every entry-state chart is expected to carry a values.yaml." >&2
    exit 1
  fi
  spliced_values="$(mktemp)"
  splice_values_block "$values_out" > "$spliced_values"

  if [ "$check_mode" -eq 1 ]; then
    if [ ! -f "$ns_out" ] || ! diff -q "$ns_out" "$tmp_ns_file" >/dev/null 2>&1; then
      stale+=("${slug}/templates/ns-user-namespaces.yaml")
    fi
    if [ ! -f "$helpers_out" ] || ! diff -q "$helpers_out" "$tmp_helpers_file" >/dev/null 2>&1; then
      stale+=("${slug}/templates/_ns-helpers.tpl")
    fi
    if ! diff -q "$values_out" "$spliced_values" >/dev/null 2>&1; then
      stale+=("${slug}/values.yaml")
    fi
    rm -f "$spliced_values"
    continue
  fi

  mkdir -p "$templates_dir"
  cp "$tmp_ns_file" "$ns_out"
  cp "$tmp_helpers_file" "$helpers_out"
  mv "$spliced_values" "$values_out"
  written=$((written + 1))
done

if [ "$check_mode" -eq 1 ]; then
  if [ "${#stale[@]}" -gt 0 ]; then
    echo "❌ ${#stale[@]} generated file(s) are stale (drifted from gitops/user-namespace/templates/):" >&2
    for s in "${stale[@]}"; do
      echo "   - gitops/entry-states/${s}" >&2
    done
    echo "   Fix: run tools/gen-entry-namespaces.sh and commit the result." >&2
    exit 1
  fi
  echo "✅ ns-user-namespaces.yaml + _ns-helpers.tpl + the manageNamespaces block in values.yaml are in sync with gitops/user-namespace/templates/ in all ${#charts[@]} entry-state charts."
  exit 0
fi

echo "✅ Wrote ns-user-namespaces.yaml + _ns-helpers.tpl + the manageNamespaces block in values.yaml into ${written} entry-state chart(s)."
