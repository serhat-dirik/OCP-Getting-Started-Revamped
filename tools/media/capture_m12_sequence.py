"""M12 (observability-health-scale) console captures, in ONE browser session.

WHY THIS EXISTS, and why it is not just another jobs file.

Two facts collide:

1. The console OAuth session on this cluster is SHORT-LIVED. Measured 2026-07-28: a profile that
   authenticated fine was already bouncing to the IdP chooser minutes later, and injecting the
   API token as an `openshift-session-token` cookie does NOT work — the console wants a real
   OAuth session. So every capture that needs the console must happen in one warm window, right
   after a human login. Asking for a login per shot is not workable.

2. M12's shots are STATE-DEPENDENT and mutually exclusive. Shot 05 must show the alert rule
   Inactive at a healthy baseline; shot 04 must show the SAME rule Firing. One namespace cannot
   be both, so the run has to drive the cluster between captures — healthy -> break claims-db ->
   wait for Firing -> restore -> HPA under load.

A jobs YAML cannot express "now scale a Deployment to 0 and wait two minutes". This can.

Everything mutating happens through `oc` with the caller's own kubeconfig; nothing here reads or
types a credential.

USE --login. It opens a headed window, waits for a human to complete the OAuth hop, and then
captures in the SAME context. Do not use the old login.py -> capture handoff: the second process
cannot open the profile until the first releases its lock, and by the time it does the session
may already be gone. One process, one context, no gap:

    cd tools/media
    KUBECONFIG=~/.kube/<cluster>.config \
    OGSR_DOMAIN=apps.cluster-<id>.<base> \
      .venv/bin/python capture_m12_sequence.py --login --profile ~/.ogsr-shot-profile --user user1
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright
from playwright.sync_api import Error as PWError

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "content" / "modules" / "ROOT" / "assets" / "images" / "observability-health-scale"


def oc(*args: str, check: bool = True) -> str:
    r = subprocess.run(["oc", *args], capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise SystemExit(f"oc {' '.join(args)} failed: {r.stderr.strip()[:200]}")
    return r.stdout.strip()


def shoot(page, url: str, wait_text: str, dest: Path, settle: int = 9000) -> bool:
    """Navigate, wait for text only the SETTLED page has, screenshot. Returns success."""
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=60_000)
    except PWError as e:
        print(f"  FAIL {dest.name}: goto {str(e).splitlines()[0][:80]}")
        return False
    if "/oauth" in page.url or "/login" in page.url:
        print(f"  FAIL {dest.name}: SESSION EXPIRED — re-run login.py and start again")
        return False
    try:
        page.wait_for_function(
            "t => !!document.body && document.body.innerText.includes(t)", arg=wait_text, timeout=90_000
        )
    except PWError:
        body = (page.inner_text("body") or "")[:150].replace("\n", " ")
        print(f"  FAIL {dest.name}: never saw {wait_text!r}; page says: {body}")
        return False
    page.wait_for_timeout(settle)
    dest.parent.mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(dest))
    kb = dest.stat().st_size // 1024
    # A splash screen or error page weighs well under 20 KB — a smoke alarm, not a correctness check.
    print(f"  ok   {dest.name}  ({kb} KB){'  <-- SUSPICIOUSLY SMALL, LOOK AT IT' if kb < 20 else ''}")
    return True


def wait_for_login(page, con: str, deadline_s: int = 900) -> bool:
    """Park on the console and wait for a human to finish the OAuth hop IN THIS WINDOW."""
    page.goto(con, wait_until="domcontentloaded", timeout=60_000)
    print("\n" + "=" * 72)
    print("  A BROWSER WINDOW IS OPEN. Log in as the attendee (IdP: workshop-users).")
    print("  Capture starts BY ITSELF the moment the console appears — don't close it.")
    print("=" * 72 + "\n", flush=True)
    start = time.time()
    while time.time() - start < deadline_s:
        try:
            u = page.url
            if "console-openshift-console" in u and not any(s in u for s in ("/oauth", "/login", "/auth/")):
                page.wait_for_timeout(3000)
                if len(page.inner_text("body")) > 200:
                    print("  logged in — starting capture\n", flush=True)
                    return True
        except PWError:
            pass
        time.sleep(2)
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", required=True)
    ap.add_argument("--user", default="user1")
    ap.add_argument("--domain", default=os.environ.get("OGSR_DOMAIN"))
    ap.add_argument("--login", action="store_true",
                    help="open HEADED, wait for a human login, then capture in the SAME context")
    a = ap.parse_args()
    if not a.domain:
        sys.exit("set --domain or $OGSR_DOMAIN")

    ns = f"{a.user}-dev"
    con = f"https://console-openshift-console.{a.domain}"
    ok = fail = 0

    with sync_playwright() as p:
        # --login keeps login and capture in ONE process and ONE context. The two-process
        # handoff (login.py writes a profile, capture reads it) is unreliable here: the console
        # session expires within minutes, and the second process cannot even open the profile
        # until the first releases its lock. Same context = no handoff, no expiry gap, no lock.
        ctx = p.chromium.launch_persistent_context(
            a.profile, channel="chrome", headless=not a.login,
            viewport={"width": 1600, "height": 1000}, ignore_https_errors=True, locale="en-US",
            args=["--no-first-run", "--no-default-browser-check"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        if a.login and not wait_for_login(page, con):
            print("TIMEOUT — no console session detected; nothing captured")
            ctx.close()
            return 1

        # ---- PHASE 1: healthy baseline -------------------------------------------------
        print("PHASE 1 — healthy baseline")
        q = ("sum(rate(http_server_requests_seconds_count%7Bnamespace%3D%22" + ns + "%22%7D%5B5m%5D))")
        for url, txt, name in [
            (f"{con}/monitoring/query-browser?query0={q}", "Metrics", "observability-health-scale-01-observe-metrics.png"),
            (f"{con}/monitoring/alertrules", "ParasolClaimsErrorRateHigh", "observability-health-scale-05-observe-alerting-inactive.png"),
            (f"{con}/observe/traces", "Traces", "observability-health-scale-02-observe-traces.png"),
        ]:
            if shoot(page, url, txt, OUT / name):
                ok += 1
            else:
                fail += 1

        # ---- PHASE 2: break the DB so the alert fires -----------------------------------
        # The rule is `for: 2m` on a 5m rate window, so this genuinely needs a few minutes.
        print(f"PHASE 2 — scaling claims-db to 0 in {ns} so 5xx climb and the rule fires")
        oc("scale", "deploy/claims-db", "-n", ns, "--replicas=0")
        deadline = time.time() + 600
        fired = False
        while time.time() < deadline:
            time.sleep(30)
            state = oc("get", "prometheusrule", "parasol-claims-alerts", "-n", ns,
                       "-o", "jsonpath={.metadata.name}", check=False)
            page.goto(f"{con}/monitoring/alerts", wait_until="domcontentloaded", timeout=60_000)
            page.wait_for_timeout(6000)
            body = page.inner_text("body")
            if "ParasolClaimsErrorRateHigh" in body and ("Firing" in body or "Pending" in body):
                if "Firing" in body:
                    fired = True
                    break
                print("    rule is Pending, waiting for Firing …")
            else:
                print(f"    waiting … (rule {state or '?'} not yet visible as Pending/Firing)")
        if fired:
            if shoot(page, f"{con}/monitoring/alerts", "ParasolClaimsErrorRateHigh",
                     OUT / "observability-health-scale-04-alert-firing.png"):
                ok += 1
            else:
                fail += 1
        else:
            print("  FAIL alert never reached Firing within 10 min — shot 04 NOT captured")
            fail += 1

        # ---- restore, always, even if the shot failed -----------------------------------
        print("  restoring claims-db to 1")
        oc("scale", "deploy/claims-db", "-n", ns, "--replicas=1")

        # ---- PHASE 3: HPA scaling under load --------------------------------------------
        print("PHASE 3 — HPA 2..4 under load")
        oc("set", "resources", "deploy/parasol-claims", "-n", ns,
           "--requests=cpu=100m,memory=256Mi", check=False)
        oc("autoscale", "deploy/parasol-claims", "-n", ns,
           "--min=2", "--max=4", "--cpu-percent=60", check=False)
        time.sleep(45)
        if shoot(page, f"{con}/topology/ns/{ns}", "parasol-claims",
                 OUT / "observability-health-scale-03-topology-hpa-scale.png", settle=12000):
            ok += 1
        else:
            fail += 1

        ctx.close()

    print(f"\n{ok} captured, {fail} failed")
    print("LOOK AT THE IMAGES before committing — a valid PNG of the wrong state is the failure mode.")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
