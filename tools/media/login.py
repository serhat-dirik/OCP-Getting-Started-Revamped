"""Open a HEADED browser on a dedicated throwaway profile so Serhat can log into the
OpenShift console once. The session cookie is then persisted in PROFILE_DIR, and the
capture script reuses it headlessly.

Nothing here reads, types, stores or transmits a credential — it opens a window, waits
for the console to be reached, and exits. The password is typed by the human into the
real OpenShift login page.
"""

import os
import sys
import time

from playwright.sync_api import sync_playwright

CONSOLE = os.environ.get("OGSR_CONSOLE") or sys.exit(
    "set $OGSR_CONSOLE to your console URL, e.g. https://console-openshift-console.apps.<cluster>.<base>/"
)
PROFILE_DIR = os.environ.get("OGSR_PROFILE", "./shot-profile")
DEADLINE_S = 900  # 15 minutes to log in, then give up rather than hang forever


def logged_in(url: str) -> bool:
    """On the console host and past the OAuth/login hop."""
    return "console-openshift-console" in url and not any(
        s in url for s in ("/oauth", "/login", "/auth/")
    )


with sync_playwright() as p:
    ctx = p.chromium.launch_persistent_context(
        PROFILE_DIR,
        channel="chrome",
        headless=False,
        viewport={"width": 1600, "height": 1000},
        ignore_https_errors=True,
        args=["--no-first-run", "--no-default-browser-check"],
    )
    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(CONSOLE, wait_until="domcontentloaded", timeout=60_000)

    print("WINDOW OPEN — log in as kubeadmin or user1 in the browser window that just appeared.")
    sys.stdout.flush()

    started = time.time()
    ok = False
    while time.time() - started < DEADLINE_S:
        try:
            if logged_in(page.url):
                # Confirm it is really the console shell, not a redirect in flight.
                page.wait_for_timeout(3000)
                if logged_in(page.url) and len(page.inner_text("body")) > 200:
                    ok = True
                    break
        except Exception:
            pass
        time.sleep(3)

    print("LOGGED_IN" if ok else "TIMEOUT — no console session detected")
    print("final url:", page.url)
    sys.stdout.flush()
    ctx.close()
