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
    url: str
    wait_text: str | None = None
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

    @property
    def out_path(self) -> Path:
        return ASSETS / self.slug / self.filename


def load_jobs(path: Path, domain: str) -> list[Job]:
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

    jobs = [Job(**entry) for entry in data["jobs"]]
    for job in jobs:
        # Substituted here, never stored: keeps live cluster domains out of the tracked tree,
        # which CI's privacy guard fails the build on.
        job.url = job.url.replace("{domain}", domain)
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


def wait_for_login(page: Any, url: str, deadline_s: int = 900) -> bool:
    """Park on `url` and wait for a human to finish the OAuth hop IN THIS WINDOW.

    Returns once the browser is past /oauth|/login|/auth/ and the page has real content.
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

        if job.wait_selector:
            page.wait_for_selector(job.wait_selector, timeout=60_000)
        if job.wait_text:
            # Not a selector: plugin tabs and table columns are plain text, and the whole point
            # is to outlast a half-mounted render that already has a title and a sidebar.
            # document.body can still be null on the first evaluation — the predicate runs as soon
            # as navigation commits, which on a redirect chain (Keycloak's account console bounces
            # through /protocol/openid-connect/auth) can be before any body exists. Without the
            # guard that raises TypeError and aborts the job instead of simply polling again.
            page.wait_for_function(
                "t => !!document.body && document.body.innerText.includes(t)",
                arg=job.wait_text,
                timeout=60_000,
            )
        if not (job.wait_selector or job.wait_text):
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--jobs", required=True, type=Path)
    ap.add_argument("--profile", type=Path, help="persistent profile dir from login.py")
    ap.add_argument("--only", help="capture just this slug")
    ap.add_argument("--no-auth", action="store_true", help="fresh context, public pages only")
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

    jobs = load_jobs(args.jobs, args.domain)
    if args.only:
        jobs = [j for j in jobs if j.slug == args.only]
    if not jobs:
        sys.exit("no jobs matched")

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
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        if getattr(args, "login", False):
            if not wait_for_login(page, args.login):
                print("TIMEOUT — no session detected in the window; nothing captured")
                ctx.close()
                return

        for job in jobs:
            if job.pre_sh:
                print(f"  pre: {job.pre_sh[:88]}", flush=True)
                r = subprocess.run(job.pre_sh, shell=True, capture_output=True, text=True, timeout=1800)
                if r.returncode != 0:
                    print(f"FAIL {job.filename}  [pre_sh rc={r.returncode}: {r.stderr.strip()[:120]}]")
                    continue
                if job.pre_wait_s:
                    print(f"  waiting {job.pre_wait_s}s for the cluster to settle", flush=True)
                    time.sleep(job.pre_wait_s)
            ok, detail = capture(page, job)
            mark = "OK  " if ok else "FAIL"
            rel = job.out_path.relative_to(REPO_ROOT)
            print(f"{mark} {rel}  [{detail}]")
            sys.stdout.flush()
            ok_count += ok

        ctx.close()

    print(f"\n{ok_count}/{len(jobs)} captured")
    return 0 if ok_count == len(jobs) else 1


if __name__ == "__main__":
    raise SystemExit(main())
