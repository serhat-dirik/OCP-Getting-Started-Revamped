#!/usr/bin/env python3
"""One-off recapture of build-deliver-04-topology-built-and-wired.png.

Loads the existing user1 session (tools/media/shot-profile.session.json), confirms identity is
user1, then shoots the grouped Topology view in user1-dev at a higher device scale factor for
label legibility. Direct script per README guidance — capture.py's Job dataclass has no
device_scale_factor knob.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

REPO_ROOT = Path(__file__).resolve().parents[2]
SESSION = Path(__file__).resolve().parent / "shot-profile.session.json"
# Never hardcode a live cluster domain in tracked source — CI's privacy guard greps tracked text
# and fails the build on one. Read it from the environment instead, same convention as capture.py.
DOMAIN = os.environ.get("OGSR_DOMAIN", "")
OUT = (REPO_ROOT / "content/modules/ROOT/assets/images/build-deliver/"
       "build-deliver-04-topology-built-and-wired.png")


def main() -> int:
    if not DOMAIN:
        sys.exit("set $OGSR_DOMAIN (e.g. apps.cluster-abcde.dyn.example.com)")
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        ctx = browser.new_context(
            storage_state=str(SESSION),
            ignore_https_errors=True,
            locale="en-US",
            viewport={"width": 1600, "height": 1000},
            device_scale_factor=2,
        )
        page = ctx.new_page()

        # Confirm identity BEFORE navigating anywhere else.
        page.goto(f"https://console-openshift-console.{DOMAIN}/", wait_until="domcontentloaded", timeout=60_000)
        who = page.evaluate(
            """async () => {
                try {
                    const r = await fetch('/api/kubernetes/apis/user.openshift.io/v1/users/~',
                        {headers: {Accept: 'application/json'}, credentials: 'same-origin'});
                    if (!r.ok) return null;
                    const j = await r.json();
                    return (j && j.metadata && j.metadata.name) || null;
                } catch (e) { return null; }
            }"""
        )
        print(f"identity: {who!r}")
        if who != "user1":
            print("STOP: not authenticated as user1", file=sys.stderr)
            ctx.close()
            browser.close()
            return 1

        url = f"https://console-openshift-console.{DOMAIN}/topology/ns/user1-dev"
        page.goto(url, wait_until="domcontentloaded", timeout=60_000)

        # Plain-text needles for the two short names; parasol-notifications renders visually
        # truncated ("paraso…ations" — the console's node-label box has a fixed max width), so it
        # is asserted via the node's `data-test-id` attribute instead of innerText.
        needles = ["parasol-claims", "claims-db"]
        for needle in needles:
            try:
                page.wait_for_function(
                    "t => !!document.body && document.body.innerText.includes(t)",
                    arg=needle, timeout=90_000,
                )
            except PlaywrightError:
                body = page.evaluate("() => document.body ? document.body.innerText : ''")
                debug_path = OUT.parent / "_debug_fail.png"
                page.screenshot(path=str(debug_path))
                print(f"STOP: never saw {needle!r} on the topology page", file=sys.stderr)
                print(f"--- body text ({len(body)} chars) ---\n{body[:3000]}", file=sys.stderr)
                print(f"debug screenshot: {debug_path}", file=sys.stderr)
                ctx.close()
                browser.close()
                return 1
        try:
            page.wait_for_function(
                "t => !!document.querySelector(`[data-test-id=\"${t}\"]`)",
                arg="parasol-notifications", timeout=90_000,
            )
        except PlaywrightError:
            debug_path = OUT.parent / "_debug_fail.png"
            page.screenshot(path=str(debug_path))
            print("STOP: no node with data-test-id='parasol-notifications'", file=sys.stderr)
            print(f"debug screenshot: {debug_path}", file=sys.stderr)
            ctx.close()
            browser.close()
            return 1

        forbid = ["Access restricted", "No resources found", "not available"]
        # Let the graph animate/settle and the grouping envelope draw before checking/shooting.
        page.wait_for_timeout(15000)
        body = page.evaluate("() => document.body ? document.body.innerText : ''")
        hit = next((t for t in forbid if t in body), None)
        if hit:
            print(f"STOP: page shows {hit!r}", file=sys.stderr)
            ctx.close()
            browser.close()
            return 1

        OUT.parent.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(OUT))
        size = OUT.stat().st_size
        print(f"wrote {OUT} ({size // 1024} KB)")
        ctx.close()
        browser.close()
        return 0 if size >= 20_000 else 2


if __name__ == "__main__":
    raise SystemExit(main())
