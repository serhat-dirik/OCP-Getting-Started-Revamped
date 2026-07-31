#!/usr/bin/env python3
"""developer-hub-golden-paths row 4 — the golden-path template form, FILLED.

WHY THIS IS NOT A jobs.yaml ENTRY. capture.py navigates and waits; it cannot TYPE. This shot's
whole subject is the form with values in it, and `wait_all_field_values` can only assert that
values are already there — it cannot put them there. Three fields, no submit, so a 40-line script
is the honest tool rather than a new capture.py feature nobody else would use.

NOTHING IS SUBMITTED. The script fills the inputs and screenshots. It never clicks Review or
Create, so it creates no Gitea repository, no catalog entry and no scaffolder task — it is safe to
re-run at any time, against any user's values, without touching that user's slot.

AUTH is one click. `app-config-rhdh` enables the Backstage guest provider outside development
(`auth.providers.guest.dangerouslyAllowOutsideDevelopment: true`), so the "Select a sign-in
method" chooser is dismissed by pressing Enter — no password is read, typed or stored.

The values default to the ones behind the two task pages captured for rows 5 and 6, so rows 4-5-6
read as one story: this form produced that run, and running it a second time produced the 409.

USAGE
    OGSR_DOMAIN=apps.<cluster>.<base> tools/media/.venv/bin/python tools/media/capture_rhdh_form.py
    ... --name parasol-policy-user1 --org user1-svcs      # to shoot a different attendee's values
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from playwright.sync_api import Error as PWError
from playwright.sync_api import sync_playwright

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "content" / "modules" / "ROOT" / "assets" / "images" / "developer-hub-golden-paths"

# react-jsonschema-form gives every field a stable `root_<property>` id. That is far more robust
# than the visible label, which carries a non-breaking thin space before its required marker
# ("Name *") and does not match a naive by-label lookup.
FIELDS = {"root_name": "name", "root_orgName": "org"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="parasol-policy-user6")
    ap.add_argument("--org", default="user6-svcs")
    ap.add_argument("--domain", default=os.environ.get("OGSR_DOMAIN", ""))
    ap.add_argument("--out", default="developer-hub-golden-paths-04-template-form.png")
    ap.add_argument(
        "--reshoot",
        action="store_true",
        help="overwrite an existing file (default refuses, per the one-shot rule)",
    )
    args = ap.parse_args()
    if not args.domain:
        sys.exit("set OGSR_DOMAIN or pass --domain")

    dest = OUT / args.out
    if dest.exists() and not args.reshoot:
        print(f"KEEP {dest.name} [already on disk; pass --reshoot to replace it]")
        return 0

    url = (
        f"https://backstage-developer-hub-rhdh.{args.domain}"
        "/create/templates/default/parasol-service-template"
    )
    values = {k: getattr(args, v) for k, v in FIELDS.items()}

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        # color_scheme is explicit on purpose: a fresh profile inherits the HOST's appearance, and
        # on a dark-mode machine Developer Hub renders its dark theme. Every other image in this
        # module is light, so an unpinned run silently produces the one shot that does not match.
        ctx = browser.new_context(
            viewport={"width": 1600, "height": 1000},
            ignore_https_errors=True,
            locale="en-US",
            color_scheme="light",
        )
        page = ctx.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=60_000)
        page.wait_for_timeout(6000)

        # The guest gate only appears on a cold context; missing is fine, not fatal.
        try:
            page.get_by_role("button", name="Enter", exact=True).first.click(timeout=6000)
        except PWError:
            pass
        page.wait_for_timeout(8000)

        for field_id, value in values.items():
            page.fill(f"#{field_id}", value)
        page.wait_for_timeout(1500)

        # Assert on the DOM, not on innerText: an <input>'s value is NOT part of innerText, so a
        # text-based check here can never pass even when the field is visibly correct.
        actual = {f: page.input_value(f"#{f}") for f in values}
        if actual != values:
            print(f"FAIL fields did not take: wanted {values}, got {actual}", file=sys.stderr)
            return 1
        owner = page.input_value("#root_owner")
        if owner != "parasol":
            print(f"FAIL Owner should default to 'parasol', got {owner!r}", file=sys.stderr)
            return 1

        dest.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(dest))
        browser.close()

    print(f"OK   {dest.relative_to(REPO)}  [{dest.stat().st_size // 1024} KB]")
    print(f"     name={values['root_name']} org={values['root_orgName']} owner={owner} (not submitted)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
