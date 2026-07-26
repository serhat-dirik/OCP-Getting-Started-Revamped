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


def capture(page: Any, job: Job) -> tuple[bool, str]:
    """Navigate, wait for REAL content, shoot. Returns (ok, detail)."""
    try:
        page.set_viewport_size(job.viewport)
        page.goto(job.url, wait_until="domcontentloaded", timeout=60_000)

        if job.wait_selector:
            page.wait_for_selector(job.wait_selector, timeout=60_000)
        if job.wait_text:
            # Not a selector: plugin tabs and table columns are plain text, and the whole point
            # is to outlast a half-mounted render that already has a title and a sidebar.
            page.wait_for_function(
                "t => document.body.innerText.includes(t)",
                arg=job.wait_text,
                timeout=60_000,
            )
        if not (job.wait_selector or job.wait_text):
            page.wait_for_load_state("networkidle", timeout=60_000)

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
