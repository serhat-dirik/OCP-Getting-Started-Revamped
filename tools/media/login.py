"""Open a HEADED browser on a dedicated throwaway profile so a human can log into the
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


def logged_in(page) -> bool:
    """Ask the console who it thinks we are, from inside the page.

    WHY NOT THE URL. This used to sniff page.url: on the console host, and not on /oauth,
    /login or /auth/ — and it was wrong twice, in opposite directions, which is what makes it
    worth a comment rather than a quiet fix.

      · False POSITIVE (2026-07-29): an empty single-page-app shell satisfies both halves. The
        capture run then started against a session that was not authenticated and produced
        screenshots of a login wall. The capture runbook warns about exactly this trap; the
        script meant to prevent it was built out of the trap.
      · False NEGATIVE (2026-07-30): a real, successful login was never recognised, so the
        window sat open until the 15-minute deadline while the human waited on it, and the
        session it had in fact captured looked like a failure.

    A URL cannot answer "am I authenticated" because authentication is not a property of the
    address bar. So ask the thing that knows. The console proxies the Kubernetes API at
    /api/kubernetes/, and `users/~` is the API's own answer to "who is this request from" — it
    needs no privileges beyond being someone. 200 with a username is proof; 401 is proof of the
    negative; anything else (proxy hiccup, page mid-navigation, fetch rejected) is not an answer
    and we keep waiting rather than guess. Returns the username, or None.
    """
    try:
        return page.evaluate(
            """async () => {
                try {
                    const r = await fetch(
                        '/api/kubernetes/apis/user.openshift.io/v1/users/~',
                        {headers: {Accept: 'application/json'}, credentials: 'same-origin'}
                    );
                    if (!r.ok) return null;
                    const j = await r.json();
                    return (j && j.metadata && j.metadata.name) || null;
                } catch (e) { return null; }
            }"""
        )
    except Exception:
        # Page navigating, context torn down, evaluate raced a reload — not an answer.
        return None


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

    # Not kubeadmin: every grounding marker is a claim about what an ATTENDEE can see and click,
    # and cluster-admin renders a different console. An admin login produces confident wrong answers.
    print(
        "WINDOW OPEN — in the window that just appeared, choose the 'workshop-users' identity\n"
        "provider and sign in as an attendee (user1). Do NOT use kubeadmin or the 'rhbk' provider."
    )
    sys.stdout.flush()

    started = time.time()
    who = None
    while time.time() - started < DEADLINE_S:
        # Every tab, not just the first. ctx.pages[0] is the tab we opened; if the login flow
        # or the human lands the console in a NEW tab, that first tab can sit on a stale login
        # page forever while a perfectly good session exists one tab over. Polling all of them
        # costs nothing and removes a whole class of "it worked but the script disagreed".
        for candidate in ctx.pages:
            who = logged_in(candidate)
            if who:
                page = candidate
                break
        if who:
            break
        time.sleep(3)

    if who:
        print(f"LOGGED_IN as {who}")
    else:
        print("TIMEOUT — no console session detected")
    print("final url:", page.url)
    sys.stdout.flush()
    ctx.close()
