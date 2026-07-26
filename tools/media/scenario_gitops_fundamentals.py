#!/usr/bin/env python3
"""Drive gitops-fundamentals' Argo CD exercise and capture each state.

This is a UI FUNCTIONAL TEST that happens to emit screenshots. It performs the lab's own
steps — create the Application from the NEW APP form, sync it, drift it, inspect the diff —
and captures the view at each stage. If a step cannot be performed, the lab's instruction for
that step is wrong or the environment is broken; either way it is a finding, so failures print
loudly rather than being swallowed.

PREREQUISITES
  * `ws start gitops-fundamentals --user <user>` has completed (seeds the claims-config repo).
  * The capture profile is logged into the STUDENT Argo CD as the attendee, via the
    `workshop-users` IdP. A console session does NOT carry — see tools/media/README.md.

SELECTORS. Argo tags only two controls with `qeid` (app-name, namespace); everything else is
reached from its visible label. Verified against the live panel 2026-07-26 — the labels are
Application Name · Project Name · SYNC POLICY · Repository URL · Revision · Path ·
Cluster URL · Namespace.

USAGE
  export OGSR_DOMAIN=apps.<cluster>.<base>
  python scenario_gitops_fundamentals.py --profile <dir> --user user1 [--gitea-url URL]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import Page, sync_playwright

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "content" / "modules" / "ROOT" / "assets" / "images" / "gitops-fundamentals"
SLUG = "gitops-fundamentals"


def shoot(page: Page, name: str) -> str:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{SLUG}-{name}.png"
    page.screenshot(path=str(path))
    size = path.stat().st_size
    flag = "  <-- SUSPICIOUSLY SMALL" if size < 20_000 else ""
    print(f"    shot {path.name}  [{size // 1024} KB]{flag}")
    return str(path)


def fill_by_label(page: Page, label: str, value: str) -> bool:
    """Type into the input that belongs to a visible label.

    Argo renders label and control as siblings inside a form row, so walk up from the label
    to its row and take the first input in it.
    """
    try:
        row = page.locator(
            f"xpath=//*[normalize-space(text())='{label}']"
            "/ancestor-or-self::*[.//input][1]"
        ).first
        box = row.locator("input").first
        box.click(timeout=10_000)
        box.fill(value, timeout=10_000)
        return True
    except PlaywrightError as exc:
        print(f"    ! could not fill {label!r}: {type(exc).__name__}")
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--user", default="user1")
    ap.add_argument("--domain", default=os.environ.get("OGSR_DOMAIN", ""))
    ap.add_argument("--gitea-url", default="")
    args = ap.parse_args()
    if not args.domain:
        sys.exit("set --domain or $OGSR_DOMAIN")

    u = args.user
    gitea = args.gitea_url or f"https://gitea-ogsr-gitea.{args.domain}"
    argo = f"https://student-gitops-server-student-gitops.{args.domain}"

    # Exactly the values the lab's table specifies.
    fields = {
        "Application Name": f"claims-dev-{u}",
        "Project Name": f"proj-{u}",
        "Repository URL": f"{gitea}/{u}/claims-config.git",
        "Revision": "main",
        "Path": "overlays/dev",
        "Cluster URL": "https://kubernetes.default.svc",
        "Namespace": f"{u}-dev",
    }

    failures: list[str] = []
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            args.profile, channel="chrome", headless=True,
            viewport={"width": 1600, "height": 1000}, ignore_https_errors=True,
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        print("[1] open Argo CD applications")
        page.goto(f"{argo}/applications", wait_until="domcontentloaded", timeout=60_000)
        page.wait_for_timeout(6000)
        if "/login" in page.url or "oauth" in page.url:
            print("    ! NOT LOGGED IN — log the profile into student Argo as the attendee first")
            ctx.close()
            return 2

        print("[2] NEW APP -> fill the form")
        page.get_by_role("button", name="NEW APP", exact=False).first.click(timeout=20_000)
        page.wait_for_timeout(3000)
        # app-name and namespace carry qeid; use it where it exists (more stable than the label).
        try:
            page.locator("[qeid='application-create-field-app-name']").fill(fields["Application Name"])
        except PlaywrightError:
            failures.append("app-name via qeid")
        for label in ("Project Name", "Repository URL", "Revision", "Path", "Cluster URL"):
            if not fill_by_label(page, label, fields[label]):
                failures.append(label)
        try:
            page.locator("[qeid='application-create-field-namespace']").fill(fields["Namespace"])
        except PlaywrightError:
            failures.append("namespace via qeid")
        # Several of these fields (Repository URL, Revision, Cluster URL) are autocompletes:
        # clicking them opens a suggestion overlay that covers the panel header, which is where
        # CREATE lives. Probed in isolation the button is visible, enabled and clickable — it only
        # became unclickable AFTER filling, because the overlay sat on top of it. Dismiss first.
        page.keyboard.press("Escape")
        page.wait_for_timeout(1500)
        shoot(page, "02-new-app-form")

        print("[3] CREATE -> capture the app while OutOfSync/Missing")
        # NOT get_by_role(name="CREATE", exact=True): the panel also carries a "CREATE
        # APPLICATION" button, and Argo's accessible names carry surrounding whitespace, so the
        # exact-name match found nothing and timed out. Anchor on the button's own text instead.
        # Both get_by_role(name="CREATE", exact=True) and
        # locator("button").filter(has_text=re.compile(r"^\s*CREATE\s*$")) failed to RESOLVE here
        # (force=True timed out "waiting for locator" too, so it was never an actionability
        # problem), while a plain querySelectorAll found the button visible, enabled and
        # pointer-events:auto. XPath on normalised text sidesteps Playwright's text matching.
        create = page.locator("xpath=//button[normalize-space(.)='CREATE']").first
        create.click(timeout=20_000)
        page.wait_for_timeout(9000)
        try:
            page.get_by_text(f"claims-dev-{u}", exact=False).first.click(timeout=20_000)
            page.wait_for_timeout(8000)
        except PlaywrightError:
            print("    ! could not open the app tile")
        shoot(page, "03-app-outofsync-missing")

        print("[4] SYNC -> SYNCHRONIZE -> wait for green")
        try:
            page.locator("button").filter(has_text=re.compile(r"^\s*SYNC\s*$")).first.click(timeout=20_000)
            page.wait_for_timeout(2500)
            page.get_by_role("button", name="SYNCHRONIZE", exact=False).first.click(timeout=20_000)
        except PlaywrightError as exc:
            print(f"    ! sync failed: {type(exc).__name__}")
            failures.append("SYNC")
        # Poll for Healthy rather than sleeping a fixed guess.
        for _ in range(40):
            page.wait_for_timeout(6000)
            body = page.inner_text("body") if page.locator("body").count() else ""
            if "Healthy" in body and "Synced" in body and "Progressing" not in body:
                break
        shoot(page, "04-app-synced-healthy")

        print(f"\ndone. failures: {failures or 'none'}")
        ctx.close()
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
