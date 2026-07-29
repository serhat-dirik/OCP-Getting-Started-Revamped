#!/usr/bin/env python3
"""Repeatable console/product-UI screenshot capture for the workshop media pass.

WHY THIS EXISTS. The media pass kept not happening because the obvious tools cannot do it:

  * An agent's in-conversation browser screenshots are returned into the transcript and
    discarded — there is no save-to-disk, so nothing ever reaches assets/images/.
  * `chrome --headless --screenshot=x.png <url>` DOES write a file, but it fires before a
    single-page app hydrates. Pointed at the Showroom cockpit it captured the Red Hat Demo
    Platform splash screen (13 KB of logo). The console is the same kind of SPA — its own
    detail pages register plugin-provided tabs seconds after `document.title` resolves, so a
    naive shot catches a half-mounted page and looks plausible while being wrong.

So captures must WAIT ON REAL CONTENT, which needs a driver. This is that driver.

AUTHENTICATION. The console needs an OAuth session, and nothing here handles a credential.
Use `--login <console-url>`: it opens a HEADED window, a human completes the OAuth hop, and
capture then proceeds IN THE SAME CONTEXT. No password is ever read, typed, stored or
transmitted.

Do NOT use the old `login.py` -> capture handoff on this cluster. It fails two ways, both
measured 2026-07-28: Chrome holds a ProcessSingleton lock on the profile so capture cannot
open it until login.py exits, and the console session expires within minutes so by the time
the handoff completes every shot can silently be a login page. (Injecting the API token as an
`openshift-session-token` cookie does not work either — the console wants a real OAuth
session.) login.py is kept only for warming a profile for LONG-LIVED sessions like Gitea.

CLUSTER DOMAIN. Job URLs must NOT hardcode a live cluster domain — CI's privacy guard fails
the build on one in any tracked file. Write `{domain}` in job URLs; it is substituted from
--domain or $OGSR_DOMAIN at run time (e.g. `apps.cluster-abcde.dyn.example.com`).

USAGE
    export OGSR_DOMAIN=apps.<your-cluster>.<base>
    python capture.py --jobs jobs.yaml --profile /path/to/shot-profile \
        --login https://console-openshift-console.$OGSR_DOMAIN [--only <slug>]
    python capture.py --jobs jobs.yaml --no-auth      # public pages, fresh context

Each job writes to content/modules/ROOT/assets/images/<slug>/<filename>, which is where the
per-module media-manifest.md expects it. Filenames follow 04-STYLE-GUIDE §4:
`<slug>-NN-short-desc.png`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

REPO_ROOT = Path(__file__).resolve().parents[2]
ASSETS = REPO_ROOT / "content" / "modules" / "ROOT" / "assets" / "images"

# The console shell renders long before plugin tabs mount. Waiting on body length alone is not
# enough — that is satisfied by the nav sidebar. Jobs should name a `wait_text` that only the
# settled page contains.
DEFAULT_VIEWPORT = {"width": 1600, "height": 1000}
SETTLE_MS = 2500


@dataclass
class Job:
    """One screenshot: where to go, how to know it arrived, what to call the file."""

    slug: str
    filename: str
    url: str = ""
    wait_text: str | None = None
    # EVERY string here must be on the page before the shot. `wait_text` alone repeatedly proved
    # too weak: a single landmark that a list page and its detail pages BOTH carry passes on the
    # wrong screen, and eleven committed screenshots were wrong exactly that way. Name the object
    # AND the state — e.g. ["ParasolClaimsErrorRateHigh", "Firing"] cannot be satisfied by the same
    # rule sitting Pending, whereas the rule name alone can.
    wait_all_text: list[str] = field(default_factory=list)
    # Strings that must appear as the VALUE OF A FORM FIELD rather than as page text.
    # `wait_all_text` tests document.body.innerText, and innerText does not include the `value` of
    # an <input>. Some console views are editable FORMS, not read-only tables: the Deployment ->
    # Environment tab renders every variable name and value in its own <input>, so
    # `wait_all_text: ["QUARKUS_OIDC_TENANT_ENABLED"]` can NEVER pass there — not because the state
    # is wrong but because the assertion is unsatisfiable by construction. Measured 2026-07-29: the
    # keycloak env shot failed that way while `oc set env deploy/parasol-claims --list` showed all
    # five variables and the page was rendering them correctly on screen.
    wait_all_field_values: list[str] = field(default_factory=list)
    # Strings that must be ABSENT at shoot time. The positive waits cannot catch a page that
    # rendered its own error: "Access restricted" / "No datapoints found" arrive WITH the heading
    # the wait is looking for, so the shot succeeds and a picture of a broken query gets committed
    # (it was — observability-health-scale-01, pulled 2026-07-28). Checked after settle_ms, before
    # the screenshot, and fatal.
    forbid_text: list[str] = field(default_factory=list)
    # Strings that must be VISIBLE IN THE FRAME the screenshot actually covers — not merely present
    # somewhere in the document.
    #
    # THIS IS THE ONLY ASSERTION THAT CATCHES A CORRECTLY-LOADED PAGE SHOT AT THE WRONG SCROLL
    # POSITION, and no amount of `wait_all_text` substitutes for it. Measured 2026-07-29:
    # trusted-supply-chain-03 asked for the ImageStream's Tags table, landed on exactly the right
    # detail page, and every wait passed — including `.sig`, which is only ever rendered by the Tags
    # rows. The rows were at y=1047..1281 in a 1000px viewport. innerText contains text that is
    # scrolled out of view, so a text wait is blind to this by definition; the shot was a valid PNG
    # of a page whose entire subject was below the fold, and only a human opening the file caught it.
    #
    # Cheap to satisfy: raise `viewport.height`, or name the section in `scroll_to_text`. Cheap to
    # get right: name the thing the caption promises, not the heading above it.
    #
    # Limits, stated honestly: this measures the element's own box against the frame. It does not
    # model an ancestor with `overflow: hidden` clipping a box that is nominally on screen, and it
    # does not know whether something is painted on top. It catches the failure that actually
    # happens — content below the fold — and it is fatal when it fires.
    require_in_frame: list[str] = field(default_factory=list)
    wait_selector: str | None = None
    settle_ms: int = SETTLE_MS
    viewport: dict[str, int] = field(default_factory=lambda: dict(DEFAULT_VIEWPORT))
    full_page: bool = False
    # Buttons to click after load, before waiting — for gates that stand between the URL and the
    # view, e.g. Developer Hub's "Select a sign-in method" chooser. Each entry is button text.
    # Missing buttons are skipped, not fatal: once a session exists the gate stops appearing, so a
    # job must work both on a cold profile and a warm one.
    click_text: list[str] = field(default_factory=list)
    # Scroll this text into view before shooting. Needed for panels that scroll INTERNALLY —
    # Argo's app-details drawer is a fixed-height overlay, so the section you want can sit below
    # the fold where neither the default shot nor full_page reaches it.
    scroll_to_text: str | None = None
    # Checkboxes that must end up TICKED. Use this, never click_text, for anything stateful:
    # Argo persists its "Compact diff" toggle across visits, so a blind click turned it OFF on
    # the second capture and silently produced the full manifest instead of the one-line diff.
    check_text: list[str] = field(default_factory=list)
    # Shell run BEFORE this job, to put the CLUSTER in the state the shot needs — materialise an
    # entry state, scale a Deployment, run a lab step. This exists because the shots are
    # state-dependent and the whole run must happen inside ONE browser session: the console
    # session cannot survive a context restart (Chrome does not persist session cookies), so
    # "capture, quit, change state, re-launch, capture" loses the login every time. Keeping the
    # context open and mutating the cluster from inside the run is the only shape that works.
    # Trusted input: these job files are repo-controlled maintainer tooling, same as a Makefile.
    pre_sh: str | None = None
    # Seconds to wait after pre_sh before shooting (rollouts, Argo syncs, alert `for:` windows).
    pre_wait_s: int = 0
    # Text to type into the page's name-filter box before waiting/shooting. Needed for the
    # console's long list views: Observe -> Alerting lists every PLATFORM rule in a virtualized
    # table, so one user-defined rule is neither on screen nor in the DOM — `wait_text` for it
    # times out on a page that is actually fine. Filtering is also what the lab tells the
    # attendee to do, so the filtered list is the honest shot, not a workaround.
    filter_text: str | None = None
    # Shell whose STDOUT is the URL to shoot, used instead of `url`. Exists because the objects
    # some shots need are named at materialisation time: `ws start` seeds PipelineRuns with a
    # random suffix, so a hardcoded run name in a job file is correct exactly once and silently
    # 404s on every later cluster. Runs after pre_sh, from REPO_ROOT, same trust model.
    url_sh: str | None = None
    # Permission to OVERWRITE a screenshot that is already on disk. Default false, and that default
    # is the point: most of these shots are state-dependent, so re-running a jobs file after the lab
    # has moved on replaces a good capture with a valid-but-wrong one and nothing looks broken (it
    # cost the M10 drift diff, 2026-07-26). A job may only clobber if the manifest actually marks
    # that row ❌ RE-CAPTURE — say so in a comment beside the flag.
    reshoot: bool = False
    # Why this shot is NOT in the run. A job carrying `parked` is never executed; the string is
    # printed instead. Keeps the reason next to the job rather than in a commit message nobody
    # re-reads (see jobs-rekor.yaml for the pattern this generalises).
    parked: str | None = None
    # Set by main() from --out-root so a grounding run can write outside the repo.
    out_root: Path = ASSETS

    @property
    def out_path(self) -> Path:
        return self.out_root / self.slug / self.filename


def load_jobs(path: Path, domain: str, out_root: Path = ASSETS) -> list[Job]:
    """Read jobs from YAML if PyYAML is present, else JSON. Keeps the dependency optional."""
    raw = path.read_text()
    data: Any
    if path.suffix in {".yaml", ".yml"}:
        try:
            import yaml  # noqa: PLC0415 - optional dependency
        except ImportError:
            sys.exit("PyYAML not installed — use a .json jobs file, or `uv pip install pyyaml`")
        data = yaml.safe_load(raw)
    else:
        data = json.loads(raw)

    jobs = [Job(**entry) for entry in data["jobs"] or []]
    for job in jobs:
        job.out_root = out_root
        if job.parked:
            continue  # a parked job carries a reason instead of a URL; it is never executed
        if bool(job.url) == bool(job.url_sh):
            sys.exit(f"{job.filename}: set exactly one of `url` or `url_sh`")
        # Substituted here, never stored: keeps live cluster domains out of the tracked tree,
        # which CI's privacy guard fails the build on. url_sh gets the same treatment so a
        # generated URL can interpolate the domain too.
        job.url = job.url.replace("{domain}", domain)
        if job.url_sh:
            job.url_sh = job.url_sh.replace("{domain}", domain)
        if "{domain}" in job.url:  # unreachable, but fail loud if the token ever changes
            sys.exit(f"unsubstituted {{domain}} in {job.filename}")
    return jobs


# Argo CD's buttons resist every Playwright locator strategy — get_by_role(exact), an anchored
# has_text filter and XPath on normalised text all time out "waiting for locator", and force=True
# fails identically (so it is not an overlay intercepting the hit test), while a plain
# querySelectorAll finds the element visible, enabled and pointer-events:auto. Measured on CREATE
# and again on DIFF, 2026-07-26. Clicking the rect the DOM itself reports sidesteps locator
# resolution entirely and works on both.
_FIND_RECT = """(label) => {
    const el = [...document.querySelectorAll('button, a, div[role="button"], label')]
        .find(e => (e.innerText || '').trim().toUpperCase() === label.toUpperCase());
    if (!el) return null;
    el.scrollIntoView({block: 'center'});
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    return {x: r.x + r.width / 2, y: r.y + r.height / 2};
}"""


def click_label(page: Any, label: str) -> bool:
    """Click a control by its exact visible text. Locator first, DOM rect as the fallback."""
    try:
        page.get_by_role("button", name=label, exact=True).first.click(timeout=8000)
        return True
    except PlaywrightError:
        pass
    try:
        rect = page.evaluate(_FIND_RECT, label)
        if not rect:
            return False
        page.mouse.click(rect["x"], rect["y"])
        page.wait_for_timeout(2500)
        return True
    except PlaywrightError:
        return False


_CHECK_STATE = """(label) => {
    const lab = [...document.querySelectorAll('label, span, div')]
        .find(e => (e.innerText || '').trim().toLowerCase() === label.toLowerCase());
    if (!lab) return null;
    // The input is usually a sibling or inside the same row as its text.
    let box = lab.querySelector('input[type=checkbox]');
    if (!box && lab.parentElement) box = lab.parentElement.querySelector('input[type=checkbox]');
    if (!box) return null;
    box.scrollIntoView({block: 'center'});
    const r = box.getBoundingClientRect();
    return {checked: box.checked, x: r.x + r.width / 2, y: r.y + r.height / 2};
}"""


def ensure_checked(page: Any, label: str) -> bool | None:
    """Leave a labelled checkbox TICKED. Returns final state, or None if not found.

    Idempotent on purpose: these toggles persist across page visits, so 'click it' is not the
    same as 'turn it on' — the second run would turn it back off.
    """
    state = page.evaluate(_CHECK_STATE, label)
    if state is None:
        return None
    if not state["checked"]:
        page.mouse.click(state["x"], state["y"])
        page.wait_for_timeout(2000)
        state = page.evaluate(_CHECK_STATE, label) or state
    return bool(state["checked"])


# The console's name-filter input is not one stable thing: PatternFly versions and console
# releases move between a `data-test-id`, an aria-label and a bare placeholder. Try the known
# ids first, then fall back to the first VISIBLE text/search input on the page — on a list view
# that is the toolbar filter. Checked in DOM order so a page-level search wins over any
# later-rendered input inside a drawer.
_FILTER_SELECTORS = (
    'input[data-test-id="item-filter"]',
    'input[data-test="name-filter-input"]',
    'input[aria-label="Search input"]',
    'input[placeholder*="Search" i]',
    'input[placeholder*="Filter" i]',
    'input[placeholder*="name" i]',
)

_ANY_FILTER_INPUT = """() => {
    const el = [...document.querySelectorAll('input')].find(e => {
        const t = (e.type || 'text').toLowerCase();
        if (t !== 'text' && t !== 'search') return false;
        const r = e.getBoundingClientRect();
        return r.width > 40 && r.height > 10;
    });
    if (!el) return null;
    el.scrollIntoView({block: 'center'});
    const r = el.getBoundingClientRect();
    return {x: r.x + r.width / 2, y: r.y + r.height / 2};
}"""


def fill_filter(page: Any, text: str, deadline_s: int = 45) -> bool:
    """Type `text` into the list view's name-filter box. Returns whether a box was found.

    Retries to a deadline: the toolbar mounts with the rest of the SPA, so on a cold page the
    input does not exist yet when navigation commits.
    """
    end = time.time() + deadline_s
    while time.time() < end:
        for sel in _FILTER_SELECTORS:
            try:
                box = page.locator(sel).first
                if box.count() and box.is_visible():
                    box.click(timeout=5000)
                    box.fill(text)
                    page.wait_for_timeout(2000)
                    return True
            except PlaywrightError:
                continue
        try:
            rect = page.evaluate(_ANY_FILTER_INPUT)
            if rect:
                page.mouse.click(rect["x"], rect["y"])
                page.keyboard.type(text, delay=40)
                page.wait_for_timeout(2000)
                return True
        except PlaywrightError:
            pass
        page.wait_for_timeout(1500)
    return False


def session_file(profile: Path) -> Path:
    """Where this profile's session cookies are cached. Beside the profile, never in the repo."""
    return profile.parent / f"{profile.name}.session.json"


def load_session(ctx: Any, path: Path) -> int:
    """Re-inject previously saved cookies. Returns how many were restored.

    THE PROBLEM THIS SOLVES. A persistent profile does NOT keep you logged into the console.
    Chrome only writes cookies that carry an expiry to its on-disk store; the console's session
    cookie has none, so it lives in memory and dies with the browser. Every capture run therefore
    began by asking a human to log in again — which made unattended capture impossible and put a
    person in the loop for what is otherwise a batch job.

    Playwright's storage_state serializes in-memory session cookies too (expires = -1), so saving
    it at the end of a run and re-adding it at the start carries the session across runs. The
    login then lasts as long as the OAuth token itself rather than as long as the process.
    """
    if not path.exists():
        return 0
    try:
        cookies = json.loads(path.read_text()).get("cookies", [])
    except (OSError, json.JSONDecodeError):
        return 0
    if not cookies:
        return 0
    try:
        ctx.add_cookies(cookies)
    except PlaywrightError:
        return 0
    return len(cookies)


def save_session(ctx: Any, path: Path) -> None:
    """Cache this context's cookies for the next run. Best-effort; never fatal.

    The file holds a live session token, so it is written 0600 and lives OUTSIDE the repo. Do not
    move it into the tree: CI's privacy guard reads text and would fail the build, and rightly so.
    """
    try:
        ctx.storage_state(path=str(path))
        path.chmod(0o600)
    except (PlaywrightError, OSError) as exc:
        print(f"  (could not cache session: {exc})", flush=True)


def wait_for_login(page: Any, url: str, deadline_s: int = 3600) -> bool:
    """Park on `url` and wait for a human to finish the OAuth hop IN THIS WINDOW.

    Returns once the browser is past /oauth|/login|/auth/ and the page has real content — so a
    profile that still holds a session proceeds immediately and nobody has to touch anything.

    The deadline is an hour because the wait is ASYNCHRONOUS in practice: the run is parked in
    the background and whoever owns the cluster logs in when they get to it. A 15-minute window
    meant a sweep that was staged and ready silently expired while its cluster state went stale.
    """
    page.goto(url, wait_until="domcontentloaded", timeout=60_000)
    print("\n" + "=" * 72)
    print("  A BROWSER WINDOW IS OPEN — log in there (attendee IdP: workshop-users).")
    print("  Capture starts BY ITSELF once you are through. Do not close the window.")
    print("=" * 72 + "\n", flush=True)
    start = time.time()
    while time.time() - start < deadline_s:
        try:
            u = page.url
            if not any(s in u for s in ("/oauth", "/login", "/auth/")) and len(page.inner_text("body")) > 200:
                print("  logged in — starting capture\n", flush=True)
                page.wait_for_timeout(2000)
                return True
        except PlaywrightError:
            pass
        time.sleep(2)
    return False


# Is each string inside the rectangle the screenshot will cover? Searches text nodes first, then
# form-field values, so the same job field works on a read-only table and on an editable form.
# `full` widens the frame to the whole scrollable document, which is what `full_page: true` shoots.
_IN_FRAME = """(args) => {
    const H = args.full ? document.documentElement.scrollHeight : window.innerHeight;
    const W = args.full ? document.documentElement.scrollWidth : window.innerWidth;
    const out = [];
    for (const t of args.needles) {
        let el = null;
        const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walk.nextNode()) {
            if (walk.currentNode.textContent.includes(t)) { el = walk.currentNode.parentElement; break; }
        }
        if (!el) {
            el = [...document.querySelectorAll('input, textarea')]
                .find(e => (e.value || '').includes(t)) || null;
        }
        if (!el) { out.push([t, 'not on the page at all']); continue; }
        const r = el.getBoundingClientRect();
        if (!r.width || !r.height) { out.push([t, 'present but has no box (hidden)']); continue; }
        if (r.top < 0 || r.left < 0 || r.bottom > H || r.right > W) {
            out.push([t, `below/outside the fold: box is ${Math.round(r.top)}..${Math.round(r.bottom)}px, `
                        + `the frame is ${W}x${H}`]);
            continue;
        }
        out.push([t, null]);
    }
    return out;
}"""


def capture(page: Any, job: Job) -> tuple[bool, str]:
    """Navigate, wait for REAL content, shoot. Returns (ok, detail)."""
    try:
        page.set_viewport_size(job.viewport)
        page.goto(job.url, wait_until="domcontentloaded", timeout=60_000)

        for label in job.click_text:
            if not click_label(page, label):
                print(f"      (no '{label}' control — continuing)")

        for label in job.check_text:
            state = ensure_checked(page, label)
            if state is None:
                print(f"      (no '{label}' checkbox — continuing)")

        if job.filter_text and not fill_filter(page, job.filter_text):
            # Fatal on purpose. A job asks to filter because the target is NOT findable on the
            # unfiltered page; shooting it anyway would write a valid PNG of the wrong view.
            return False, f"no filter box found for {job.filter_text!r}"

        if job.wait_selector:
            page.wait_for_selector(job.wait_selector, timeout=60_000)
        # Not selectors: plugin tabs, table columns and status words are plain text, and the whole
        # point is to outlast a half-mounted render that already has a title and a sidebar.
        # document.body can still be null on the first evaluation — the predicate runs as soon as
        # navigation commits, which on a redirect chain (Keycloak's account console bounces through
        # /protocol/openid-connect/auth) can be before any body exists. Without the guard that
        # raises TypeError and aborts the job instead of simply polling again.
        waits = ([job.wait_text] if job.wait_text else []) + list(job.wait_all_text)
        for needle in waits:
            try:
                page.wait_for_function(
                    "t => !!document.body && document.body.innerText.includes(t)",
                    arg=needle,
                    timeout=60_000,
                )
            except PlaywrightError:
                # Name the string that was missing. "TimeoutError: waiting for function" alone
                # sends you re-reading the whole job to guess which assertion failed.
                return False, f"never saw {needle!r} — wrong view, or the state was not reached"
        for needle in job.wait_all_field_values:
            try:
                page.wait_for_function(
                    "t => [...document.querySelectorAll('input, textarea')]"
                    "        .some(e => (e.value || '').includes(t))",
                    arg=needle,
                    timeout=60_000,
                )
            except PlaywrightError:
                return False, (f"never saw {needle!r} in any form field — wrong view, or the state "
                               f"was not reached (if the page shows it as TEXT, use wait_all_text)")
        if not (job.wait_selector or waits or job.wait_all_field_values):
            page.wait_for_load_state("networkidle", timeout=60_000)

        if job.scroll_to_text:
            # Locators are unreliable on some of these UIs (see click_label), so find the node in
            # the DOM and let the browser scroll its own container.
            found = page.evaluate(
                """(t) => {
                    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                    while (walk.nextNode()) {
                        if (walk.currentNode.textContent.trim() === t) {
                            const el = walk.currentNode.parentElement;
                            if (el) { el.scrollIntoView({block: 'center'}); return true; }
                        }
                    }
                    return false;
                }""",
                job.scroll_to_text,
            )
            if not found:
                return False, f"scroll target {job.scroll_to_text!r} not present"
            page.wait_for_timeout(1500)

        page.wait_for_timeout(job.settle_ms)

        if job.forbid_text:
            # AFTER the settle, so a late-arriving error banner is caught. A positive wait cannot
            # see these: "Access restricted" renders beside the very heading the wait matched.
            body = page.evaluate("() => document.body ? document.body.innerText : ''")
            hit = next((t for t in job.forbid_text if t in body), None)
            if hit:
                return False, f"page shows {hit!r} — refusing to shoot a broken view"

        if job.require_in_frame:
            # LAST check before the shutter, because it measures the frame as it will be shot —
            # after every click, filter, scroll and settle has moved the page around.
            misses = [(t, why) for t, why in
                      page.evaluate(_IN_FRAME, {"needles": job.require_in_frame,
                                                "full": job.full_page}) if why]
            if misses:
                return False, ("not in frame: "
                               + "; ".join(f"{t!r} {why}" for t, why in misses))

        job.out_path.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(job.out_path), full_page=job.full_page)
        size = job.out_path.stat().st_size
        # A splash screen or error page is small. Not proof of correctness, but it catches the
        # exact failure mode that made the raw-chrome attempt useless.
        if size < 20_000:
            return False, f"suspiciously small ({size} B) — likely a splash/error page"
        return True, f"{size // 1024} KB"
    except PlaywrightError as exc:
        return False, f"{type(exc).__name__}: {str(exc).splitlines()[0][:160]}"


def print_plan(jobs: list[Job], path: Path) -> int:
    """Dry-run the jobs file: what runs, what is skipped, what each shot will cost.

    Exists because the expensive input to a capture run is a human being available to complete an
    OAuth login. Discovering a broken job file, or that six jobs would overwrite good screenshots,
    AFTER that person has logged in wastes the one thing the run cannot manufacture.
    """
    print(f"\nPLAN for {path.name}\n" + "=" * 72)
    will_run = 0
    budget_s = 0
    for job in jobs:
        if job.parked:
            print(f"  PARK  {job.slug}/{job.filename}")
            print(f"        {' '.join(job.parked.split())[:150]}")
            continue
        if job.out_path.exists() and not job.reshoot:
            print(f"  KEEP  {job.slug}/{job.filename}  (on disk; no `reshoot: true`)")
            continue
        will_run += 1
        budget_s += job.pre_wait_s + job.settle_ms // 1000
        flag = "  [RESHOOT — replaces a file on disk]" if job.reshoot else ""
        print(f"  RUN   {job.slug}/{job.filename}{flag}")
        if job.pre_sh:
            print(f"        pre: {' '.join(job.pre_sh.split())[:140]}")
        if job.pre_wait_s:
            print(f"        then wait {job.pre_wait_s}s")
        asserts = ([job.wait_text] if job.wait_text else []) + list(job.wait_all_text)
        asserts += [f"{v} (form field)" for v in job.wait_all_field_values]
        print(f"        assert present: {asserts or '(none — WEAK, the shot is unguarded)'}")
        if job.forbid_text:
            print(f"        assert absent : {job.forbid_text}")
        if job.require_in_frame:
            print(f"        assert in frame: {job.require_in_frame}  "
                  f"(viewport {job.viewport['width']}x{job.viewport['height']})")
        else:
            # Not fatal, but say it every time: a job with no framing assertion can produce a
            # perfect page with its subject scrolled off screen, and nothing but a human opening
            # the PNG will ever notice.
            print("        assert in frame: (none — the subject could be below the fold)")
    print("-" * 72)
    print(f"  {will_run} to capture · at least ~{budget_s // 60}m{budget_s % 60:02d}s of waiting, "
          f"excluding pre_sh run time (ws start/solve can each be 5-25 min)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--jobs", required=True, type=Path)
    ap.add_argument("--profile", type=Path, help="persistent profile dir from login.py")
    ap.add_argument(
        "--only",
        help="run only jobs whose SLUG equals this, or whose FILENAME contains it. The filename "
             "form is what you want after a partial run: `--only 04-alert-firing` retries one shot "
             "instead of re-staging the module's other four.",
    )
    ap.add_argument(
        "--out-root", type=Path, default=ASSETS,
        help="where screenshots are written (default: content/modules/ROOT/assets/images). Point it "
             "OUTSIDE the repo for a grounding run — pages shot only to read a console label are "
             "reference material, not workshop assets, and must not land in the tree.",
    )
    ap.add_argument(
        "--no-pre", action="store_true",
        help="skip every job's `pre_sh` (and its pre_wait_s) and shoot the cluster AS IT IS. For "
             "retrying a shot that failed on the CAPTURE side — a wrong wait, a bad viewport — "
             "when the state it needs is already staged and correct. Re-running `pre_sh` there is "
             "not free: most of these begin with `ws start`, which PURGES the namespace and "
             "re-materialises it, so a retry can destroy a good state and, on a loaded cluster, "
             "fail to bring it back. Verify the state yourself first (`oc get`/`oc set env --list`) "
             "— with this flag nothing else will. `url_sh` still runs; it resolves the target.",
    )
    ap.add_argument("--no-auth", action="store_true", help="fresh context, public pages only")
    ap.add_argument(
        "--plan", action="store_true",
        help="print what this file WOULD do — run / KEEP / PARK per job, plus the staging commands "
             "— and exit. No browser, no cluster, no login. Run this before the real capture: the "
             "console login is a human's time and a jobs file that fails to load, or that would "
             "clobber a good screenshot, should be found before anyone is asked for it.",
    )
    ap.add_argument(
        "--login", metavar="URL",
        help="open HEADED at URL, wait for a human to log in, then capture in the SAME context. "
             "Use this instead of the login.py handoff — see the comment at the context setup.",
    )
    ap.add_argument(
        "--domain",
        default=os.environ.get("OGSR_DOMAIN", ""),
        help="cluster apps domain substituted for {domain} in job URLs (or $OGSR_DOMAIN)",
    )
    args = ap.parse_args()

    if not args.domain:
        sys.exit("set --domain or $OGSR_DOMAIN (e.g. apps.cluster-abcde.dyn.example.com)")

    jobs = load_jobs(args.jobs, args.domain, args.out_root)
    if args.only:
        jobs = [j for j in jobs if j.slug == args.only or args.only in j.filename]
    if not jobs:
        sys.exit("no jobs matched")

    if args.plan:
        return print_plan(jobs, args.jobs)

    if not args.no_auth and not args.profile:
        sys.exit("--profile is required unless --no-auth is given (run login.py first)")

    ok_count = 0
    with sync_playwright() as p:
        # locale is NOT cosmetic. Gitea honours Accept-Language, so on a machine set to another
        # locale it renders its whole UI translated — a capture came back with "Değişiklikleri
        # Uygula" where the lab says "Commit Changes". Pin en-US so screenshots always match the
        # English labels the content names, whoever runs the capture.
        if args.no_auth:
            browser = p.chromium.launch(channel="chrome", headless=True)
            ctx = browser.new_context(
                viewport=DEFAULT_VIEWPORT, ignore_https_errors=True, locale="en-US"
            )
        else:
            # --login runs HEADED so a human can complete the OAuth hop, then captures in this
            # SAME context. Do not go back to the login.py -> capture handoff: Chrome holds a
            # ProcessSingleton lock on the profile (so the capture cannot open it until login.py
            # exits), and this cluster's console session expires within minutes (so by the time
            # the handoff completes the session may be gone and every shot is a login page).
            ctx = p.chromium.launch_persistent_context(
                str(args.profile),
                channel="chrome",
                headless=not args.login,
                viewport=DEFAULT_VIEWPORT,
                ignore_https_errors=True,
                locale="en-US",
                args=["--no-first-run", "--no-default-browser-check"],
            )
        sess_path = session_file(Path(args.profile)) if args.profile else None
        if sess_path:
            n = load_session(ctx, sess_path)
            if n:
                print(f"  restored {n} cached cookies from a previous run", flush=True)

        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        if getattr(args, "login", False):
            if not wait_for_login(page, args.login):
                print("TIMEOUT — no session detected in the window; nothing captured")
                if sess_path:
                    save_session(ctx, sess_path)
                ctx.close()
                return 1  # not `return` — a bare return exits 0 and a wrapper reads that as success
            # Cache immediately, not at the end: if a later job crashes the run, the session a
            # human just spent time establishing must not die with it.
            if sess_path:
                save_session(ctx, sess_path)

        attempted = 0
        for job in jobs:
            rel = f"{job.slug}/{job.filename}"
            if job.parked:
                print(f"PARK {rel}  [{job.parked}]")
                continue
            if job.out_path.exists() and not job.reshoot:
                # The screenshots are state-dependent, so a second run of a jobs file does not
                # produce the same picture — it produces whatever the lab looks like NOW, which is
                # a valid PNG of the wrong moment and silently replaces a good one. Overwriting is
                # therefore opt-in per job (`reshoot: true`), set only when the module's
                # media-manifest.md actually marks that row ❌ RE-CAPTURE.
                print(f"KEEP {rel}  [already on disk; set `reshoot: true` to replace it]")
                continue
            attempted += 1
            if job.pre_sh and args.no_pre:
                print(f"  pre: SKIPPED (--no-pre) — shooting the cluster as it is: {job.pre_sh[:60]}",
                      flush=True)
            elif job.pre_sh:
                print(f"  pre: {job.pre_sh[:88]}", flush=True)
                # cwd=REPO_ROOT is load-bearing. pre_sh commands are written repo-root-relative
                # (`./tools/ws/ws start …`) because that is how every other tool in this repo is
                # invoked. Without this the shell inherits tools/media as its cwd and EVERY
                # `ws start` dies with rc=127 "No such file or directory" — which then cascades:
                # the entry state is never materialised, so the follow-on `oc scale` reports
                # "no objects passed to scale", and the shots that do not need staging still
                # succeed, so the run reports partial success while the staged shots are junk.
                # Measured 2026-07-28: 7 of 9 failed exactly this way.
                r = subprocess.run(job.pre_sh, shell=True, capture_output=True, text=True,
                                   timeout=1800, cwd=REPO_ROOT)
                if r.returncode != 0:
                    print(f"FAIL {job.filename}  [pre_sh rc={r.returncode}: {r.stderr.strip()[:120]}]")
                    continue
                if job.pre_wait_s:
                    print(f"  waiting {job.pre_wait_s}s for the cluster to settle", flush=True)
                    time.sleep(job.pre_wait_s)
            if job.url_sh:
                # Resolved AFTER pre_sh: the object being addressed is usually the one pre_sh
                # just created. An empty result means the object is not there — fail loudly
                # rather than navigating to a truncated URL and shooting whatever answers.
                u = subprocess.run(job.url_sh, shell=True, capture_output=True, text=True,
                                   timeout=120, cwd=REPO_ROOT)
                job.url = u.stdout.strip()
                if u.returncode != 0 or not job.url:
                    print(f"FAIL {job.filename}  [url_sh rc={u.returncode}: "
                          f"{(u.stderr.strip() or 'empty URL')[:120]}]")
                    continue
            ok, detail = capture(page, job)
            mark = "OK  " if ok else "FAIL"
            print(f"{mark} {rel}  [{detail}]")
            sys.stdout.flush()
            ok_count += ok

        # Re-cache at the end too, not only right after --login. The console can rotate its session
        # cookie mid-run, and the point of the cache is that ONE human login serves every later
        # run: a stale cached copy quietly puts a person back in the loop.
        if sess_path:
            save_session(ctx, sess_path)
        ctx.close()

    skipped = len(jobs) - attempted
    print(f"\n{ok_count}/{attempted} captured ({skipped} parked or already on disk)")
    return 0 if ok_count == attempted else 1


if __name__ == "__main__":
    raise SystemExit(main())
