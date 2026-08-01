#!/usr/bin/env python3
"""Capture the two gitops-at-scale TERMINAL rows: the canary mid-flight (4a) and the abort (5).

Why a bespoke script and not a capture.py jobs file
---------------------------------------------------
Both rows are the attendee's own Showroom ttyd terminal, and `capture.py`'s safety model does not
survive the trip: xterm.js paints to a CANVAS, so `document.body.innerText` is the empty string and
`wait_all_text` / `forbid_text` / `require_in_frame` are all silently blind — a jobs file would
happily shoot a half-rendered or entirely wrong screen and report success. ttyd exposes the terminal
object as `window.term`, whose scrollback buffer reads back as real text; every assertion below runs
against THAT string. Do not point a plain capture.py job at ttyd.

The frames are dark on purpose. The "force light theme" rule is about product UIs (console, Argo,
Gitea, Developer Hub) which render dark on a fresh profile; this is the attendee's real terminal.

No login anywhere: `https://showroom-<user>.<domain>/tty-top/` answers 200 anonymously and the shell
it hands you is already the attendee (`oc whoami` returns the user).

How the canary is triggered — READ THIS BEFORE RE-RUNNING
---------------------------------------------------------
The LAB triggers the canary by editing the image tag in Gitea and letting Argo CD sync the commit.
This script instead patches the Rollout's image directly, which is the mechanism the module's own
DEMO flavor uses and which `ws solve` is built for: the solve-state prod Application carries
`selfHeal: false` precisely so the canary can be driven by hand without Argo reverting it (see the
header of gitops/entry-states/gitops-at-scale/templates/solve-endstate.yaml). The Rollout, the
steps, the AnalysisRun and every line in the captured frames are therefore genuine — only the thing
that set the new image differs, and the frames never show it (the screen is cleared after the
patch). Stated here so nobody has to reverse-engineer it from a PNG.

Usage:
    OGSR_DOMAIN=apps.cluster-xxxxx.dyn.redhatworkshops.io \
    KUBECONFIG=... .venv/bin/python capture_m11_canary.py --user user4 [--step 4a|5] [--dry-run]
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

ASSETS = Path(__file__).resolve().parents[2] / "content/modules/ROOT/assets/images/gitops-at-scale"

# Read the REAL text out of xterm.js. document.body.innerText is "" on a canvas renderer.
READ_BUF = """() => {
  if (!window.term) return null;
  const b = window.term.buffer.active;
  const out = [];
  for (let i = 0; i < b.length; i++) {
    const l = b.getLine(i);
    if (l) out.push(l.translateToString(true));
  }
  return out.join("\\n");
}"""

# xterm.js default here is ~13px at 160 columns — legible on a 1280px screenshot only if you are
# looking for it. Bump the font and let ttyd's fit addon reflow (it also resizes the pty).
SET_FONT = """(size) => {
  window.term.options.fontSize = size;
  if (window.term._core && window.term._core.viewport) window.term._core.viewport.syncScrollArea();
  window.dispatchEvent(new Event("resize"));
}"""

# Exercise 3's watch loop, verbatim from lab.adoc.
EX3_LOOP = """echo "waiting for the canary to start (Argo syncing your commit)…"
CANARY_STARTED=""
for i in $(seq 1 20); do
  oc get rollout parasol-claims -n $PROD \\
    -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q ':1.1' \\
    && { CANARY_STARTED=yes; break; }
  sleep 6
done
if [ -z "$CANARY_STARTED" ]; then
  echo "  ✗ the canary never started — Argo has not synced your commit yet."
else
  for i in $(seq 1 30); do
    S=$(oc get rollout parasol-claims -n $PROD -o jsonpath='{.status.currentStepIndex}')
    P=$(oc get rollout parasol-claims -n $PROD -o jsonpath='{.status.phase}')
    U=$(oc get rollout parasol-claims -n $PROD -o jsonpath='{.status.updatedReplicas}')
    A=$(oc get analysisrun -n $PROD --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)
    echo "  $(date +%T)  step $S/5   $P   canary-pods:${U:-0}/4   analysis:${A:-none}"
    [ "$P" = "Healthy" ] && [ "$S" = "5" ] && { echo "  ✔ promoted to 100%"; break; }
    sleep 7
  done
fi
"""

# Exercise 4's watch loop, verbatim from lab.adoc.
EX4_LOOP = """for i in $(seq 1 22); do
  P=$(oc get rollout parasol-claims -n $PROD -o jsonpath='{.status.phase}')
  A=$(oc get analysisrun -n $PROD --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)
  echo "  $(date +%T)  rollout: $P   analysis: ${A:-none}"
  [ "$P" = "Degraded" ] && { echo "  ✖ canary aborted — analysis failed"; break; }
  sleep 7
done
"""


IMAGE_PATCH = ('[{"op":"replace","path":"/spec/template/spec/containers/0/image",'
               '"value":"image-registry.openshift-image-registry.svc:5000/'
               'ogsr-parasol-images/parasol-claims:%s"}]')


# A click-to-run block reaches the tty in ONE write, and bash ECHOES the whole multi-line construct
# back (with `>` continuation prompts) before running a line of it. That echo contains the loop's own
# `echo "…step $S/5 … analysis:${A:-none}"` and `echo "  promoted to 100%"` source — so a naive
# substring search over the scrollback matches the SOURCE and fires before the canary has done
# anything. Measured 2026-08-01: the first attempt at row 4a shot at `analysis:Running` while
# claiming it had seen `promoted to 100%`, because that string was sitting in the echoed source ten
# lines above. Assert only against lines the loop actually PRINTED: a timestamped status line, or one
# of its terminal verdicts standing alone (never inside an `echo` statement).
TIMESTAMPED = re.compile(r"^\s*\d\d:\d\d:\d\d\s")
VERDICTS = ("✔ promoted to 100%", "✖ canary aborted")


def emitted(buf: str) -> str:
    """The subset of the scrollback the shell PRINTED, with its own echoed source removed."""
    keep = []
    for line in buf.splitlines():
        if TIMESTAMPED.match(line):
            keep.append(line)
        elif any(v in line for v in VERDICTS) and "echo" not in line and "break" not in line:
            keep.append(line)
        elif line.startswith("RolloutAborted:") or "prod health through the abort:" in line:
            if "curl" not in line and "echo" not in line:
                keep.append(line)
    return "\n".join(keep)


class Tty:
    def __init__(self, page):
        self.page = page

    def read(self) -> str:
        buf = self.page.evaluate(READ_BUF)
        if buf is None:
            raise RuntimeError("window.term is not exposed — this is not a ttyd page, or it has "
                               "not finished loading. Refusing to shoot a screen we cannot read.")
        return buf

    def send(self, text: str) -> None:
        self.page.click(".xterm-screen")
        self.page.keyboard.type(text)

    def wait_for(self, needles: list[str], timeout_s: int, label: str,
                 output_only: bool = False) -> str:
        """Block until every needle is in the live scrollback. Fatal on timeout.

        output_only=True searches ONLY what the shell printed, never its echoed source — use it for
        anything asserted on a pasted multi-line block (see the `emitted` note above).
        """
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            buf = self.read()
            hay = emitted(buf) if output_only else buf
            if all(n in hay for n in needles):
                return hay
            time.sleep(1.5)
        raise SystemExit(f"FAIL [{label}]: never saw {needles!r} in the terminal within "
                         f"{timeout_s}s. Not shooting. Last output:\n{emitted(self.read())[-1200:]}")


def shoot(page, tty: Tty, out: Path, needles: list[str], label: str, dry: bool) -> None:
    buf = emitted(tty.read())
    missing = [n for n in needles if n not in buf]
    if missing:
        raise SystemExit(f"FAIL [{label}]: {missing!r} absent at shoot time.")
    if dry:
        out = Path("/tmp") / f"dry-{out.name}"
    elif out.exists():
        raise SystemExit(f"FAIL [{label}]: {out} already exists. These shots are one-shot; "
                         f"delete it deliberately if you really mean to re-capture.")
    page.screenshot(path=str(out))
    print(f"OK   {out}  [{out.stat().st_size // 1024} KB]  asserted: {needles}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="user4")
    ap.add_argument("--domain", default=os.environ.get("OGSR_DOMAIN", ""))
    ap.add_argument("--step", choices=["4a", "5"], required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--font", type=int, default=17)
    a = ap.parse_args()
    if not a.domain:
        sys.exit("set --domain or OGSR_DOMAIN")

    prod = f"{a.user}-prod"
    url = f"https://showroom-{a.user}.{a.domain}/tty-top/"

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome", headless=True)
        ctx = browser.new_context(viewport={"width": 1280, "height": 560}, ignore_https_errors=True)
        page = ctx.new_page()
        page.goto(url, wait_until="networkidle", timeout=60000)
        page.wait_for_timeout(4000)
        tty = Tty(page)
        page.evaluate(SET_FONT, a.font)
        page.wait_for_timeout(1500)

        # Prove we are the attendee before doing anything else — a ttyd that handed us the wrong
        # shell would otherwise be indistinguishable from the right one in a screenshot.
        tty.send(f"clear; oc whoami\n")
        tty.wait_for([a.user], 20, "identity")
        tty.send(f"clear; PROD={prod}; echo \"production: $PROD\"\n")
        tty.wait_for([f"production: {prod}"], 20, "PROD set")

        if a.step == "4a":
            # Trigger, then clear so the frame carries only the lab's own watch loop.
            # Typed into the attendee's own terminal, so the mutation happens as {user} and not as
            # whatever identity this script's kubeconfig holds. JSON patch, not merge: a Rollout is
            # a CRD, so `--type merge` is a JSON MERGE patch and would REPLACE the whole containers
            # array — taking the env, ports and probes with it.
            tty.send(f"clear; oc patch rollout parasol-claims -n $PROD --type json -p "
                     f"'{IMAGE_PATCH % '1.1'}'\n")
            tty.wait_for(["patched"], 30, "image -> 1.1")
            tty.send("clear\n")
            time.sleep(1)
            tty.send(EX3_LOOP)
            # Wait for the loop to RUN OUT, not just to reach the analysis step. Shooting the
            # instant `analysis:Running` appears leaves only ~9 output lines on screen, and a
            # click-to-run block echoes ~20 lines of its own source above them (bash reprints a
            # multi-line construct with `>` continuations), so two thirds of the frame is source and
            # the progression is a sliver at the bottom. Letting it finish fills the visible rows
            # with the story and pushes the echoed source off the top — and the mid-canary lines
            # this row asks for (`canary-pods:2/4`, `analysis:Running`) are still in the frame,
            # now with the steps either side of them for context.
            tty.wait_for(["canary-pods:2/4", "analysis:Running", "✔ promoted to 100%"], 420,
                         "canary", output_only=True)
            shoot(page, tty, ASSETS / "gitops-at-scale-04-canary-progressing.png",
                  ["canary-pods:1/4", "Paused", "canary-pods:2/4", "analysis:Running",
                   "analysis:Successful", "✔ promoted to 100%"],
                  "4a", a.dry_run)

        else:  # step 5 — the abort
            tty.send(f"clear; oc patch configmap gitops-at-scale-canary-control -n $PROD "
                     f"--type merge -p '{{\"data\":{{\"verdict\":\"fail\"}}}}'\n")
            tty.wait_for(["patched"], 30, "verdict=fail")
            tty.send(f"oc patch rollout parasol-claims -n $PROD --type json -p "
                     f"'{IMAGE_PATCH % '1.0'}'\n")
            tty.wait_for(["patched"], 30, "image -> 1.0")
            tty.send("clear\n")
            time.sleep(1)
            tty.send(EX4_LOOP)
            tty.wait_for(["✖ canary aborted"], 420, "abort", output_only=True)
            # The row also asks for the AnalysisRun evidence and the route still answering 200 —
            # the two blocks the lab runs immediately after the loop.
            tty.send(
                "oc get rollout parasol-claims -n $PROD -o jsonpath='{.status.message}{\"\\n\"}'\n")
            time.sleep(3)
            tty.send(
                "ROUTE=$(oc get route parasol-claims -n $PROD -o jsonpath='{.spec.host}'); "
                "curl -s -o /dev/null -w \"prod health through the abort: %{http_code}\\n\" "
                "\"http://$ROUTE/q/health/ready\"\n")
            tty.wait_for(["prod health through the abort: 200"], 60, "route 200")
            shoot(page, tty, ASSETS / "gitops-at-scale-05-canary-aborted.png",
                  ["✖ canary aborted", "RolloutAborted", "prod health through the abort: 200"],
                  "5", a.dry_run)

        browser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
