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
Run `login.py` once: it opens a HEADED window on a throwaway profile directory, a human logs
in, and the session cookie persists in that profile. This script then reuses the profile
headlessly. No password is ever read, typed, stored or transmitted by either script.

CLUSTER DOMAIN. Job URLs must NOT hardcode a live cluster domain — CI's privacy guard fails
the build on one in any tracked file. Write `{domain}` in job URLs; it is substituted from
--domain or $OGSR_DOMAIN at run time (e.g. `apps.cluster-abcde.dyn.example.com`).

USAGE
    export OGSR_DOMAIN=apps.<your-cluster>.<base>
    python capture.py --jobs jobs.yaml --profile /path/to/shot-profile [--only <slug>]
    python capture.py --jobs jobs.yaml --no-auth      # public pages, fresh context

Each job writes to content/modules/ROOT/assets/images/<slug>/<filename>, which is where the
per-module media-manifest.md expects it. Filenames follow 04-STYLE-GUIDE §4:
`<slug>-NN-short-desc.png`.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
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
        if args.no_auth:
            browser = p.chromium.launch(channel="chrome", headless=True)
            ctx = browser.new_context(viewport=DEFAULT_VIEWPORT, ignore_https_errors=True)
        else:
            ctx = p.chromium.launch_persistent_context(
                str(args.profile),
                channel="chrome",
                headless=True,
                viewport=DEFAULT_VIEWPORT,
                ignore_https_errors=True,
            )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        for job in jobs:
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
