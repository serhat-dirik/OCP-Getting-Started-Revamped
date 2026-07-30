"""Open a HEADED browser on a dedicated throwaway profile so a human can log into the
OpenShift console once, then SAVE that session to disk so headless capture runs reuse it.

Nothing here reads, types, stores or transmits a credential — it opens a window, waits
for the console to be reached, and exits. The password is typed by the human into the
real OpenShift login page.

WHY THE SAVE IS THE WHOLE POINT (measured 2026-07-30, after a login was lost).
The profile directory alone does NOT keep you logged into the console. Chrome only writes
cookies that carry an expiry to its on-disk store, and the console's session cookie has
none — it lives in memory and dies with the browser. Measured on a profile whose human
login had just succeeded: `openshift-refresh-token` persisted with a 30-day expiry, while
the session cookie and csrf-token showed `expires = NULL`, and a later headless run got
401 and was bounced to /oauth/authorize. The refresh token on its own is NOT enough — the
console demands the interactive hop again.

So a login that is not exported dies with the window it was typed into. capture.py already
knew this and caches storage_state (see its load_session docstring); login.py did not, which
is why it could report success and still leave nothing behind. Both now write the SAME file,
`<profile>.session.json`, so either one can establish the session and the other picks it up.

That file holds a live session token: 0600, outside the repo, never committed. CI's privacy
guard reads text and would fail the build on it, rightly.
"""

import json
import os
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

CONSOLE = os.environ.get("OGSR_CONSOLE") or sys.exit(
    "set $OGSR_CONSOLE to your console URL, e.g. https://console-openshift-console.apps.<cluster>.<base>/"
)
PROFILE_DIR = os.environ.get("OGSR_PROFILE", "./shot-profile")
DEADLINE_S = 900  # 15 minutes to log in, then give up rather than hang forever

# Must match capture.py's session_file() exactly — the two scripts share this file, and a
# disagreement about its name is a silent "please log in again" for the human.
SESSION_FILE = Path(PROFILE_DIR).parent / f"{Path(PROFILE_DIR).name}.session.json"


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
    # Re-inject a session cached by an earlier login.py or capture.py run. If it is still good the
    # human is never asked to do anything — which is the difference between "one login per window"
    # and "one login per token lifetime".
    restored = 0
    if SESSION_FILE.exists():
        try:
            cookies = json.loads(SESSION_FILE.read_text()).get("cookies", [])
            if cookies:
                ctx.add_cookies(cookies)
                restored = len(cookies)
        except Exception as exc:  # corrupt/unreadable cache is not a reason to fail the login
            print(f"(ignoring unusable session cache: {exc})")

    page = ctx.pages[0] if ctx.pages else ctx.new_page()
    page.goto(CONSOLE, wait_until="domcontentloaded", timeout=60_000)

    if restored:
        page.wait_for_timeout(3000)
        already = logged_in(page)
        if already:
            print(f"ALREADY_LOGGED_IN as {already} — {restored} cookies restored, nothing to do.")
            sys.stdout.flush()
            ctx.close()
            sys.exit(0)
        print(f"(cached session no longer valid — {restored} cookies restored but the console said no)")

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
        # Export BEFORE closing. storage_state serializes in-memory session cookies too
        # (expires = -1), which is the only way this login outlives the window it was typed
        # into. Skipping this is exactly how a successful login was lost on 2026-07-30.
        try:
            ctx.storage_state(path=str(SESSION_FILE))
            SESSION_FILE.chmod(0o600)
            n = len(json.loads(SESSION_FILE.read_text()).get("cookies", []))
            print(f"LOGGED_IN as {who} — session saved ({n} cookies) to {SESSION_FILE}")
        except Exception as exc:
            # Loud, because the login succeeded but bought nothing: the next run will ask again.
            print(f"LOGGED_IN as {who} — BUT COULD NOT SAVE THE SESSION: {exc}")
            print("  The next capture run will have to ask for a login again.")
    else:
        print("TIMEOUT — no console session detected")
    print("final url:", page.url)
    sys.stdout.flush()
    ctx.close()
