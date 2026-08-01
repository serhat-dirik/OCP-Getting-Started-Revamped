"""M17 (deployment-targets-scheduling) shot 01 — the Pods list WITH a Node column.

WHY THIS EXISTS, and why it is not a row in jobs-m14-m19-console.yaml.

The row was a job. It failed on 2026-08-01 with `never saw 'Node'`, against a namespace that was
in exactly the right state — three `parasol-claims` replicas on three different nodes, proven from
the API. The state was never the problem. **The console's Pods list has no Node column at all by
default.** Grounded the same day at 1600x1100 as user7: the default columns are Name, Status,
Ready, Restarts, Owner, Memory, CPU, Created — and nothing else. `deployment-targets-scheduling`'s
own `[CAPTURE-VERIFY]` marker at lab.adoc:168/:176 had already suspected this; this run settles it.

Adding the column is a three-step interaction — open *Column management*, tick **Node**, *Save* —
and `capture.py` deliberately cannot express it: `click_text` clicks controls that HAVE text (the
column-management control is an icon button), `check_text` ticks a checkbox but runs before any
click could have opened the dialog it lives in, and there is no post-tick click at all. Rather than
grow the generic harness a bespoke three-step sequencer for one shot, this follows the pattern the
directory already established for interactions a jobs file cannot describe (see
`capture_m12_sequence.py`, `capture_m11_canary.py`).

The control is addressed by `button[data-test="manage-columns"]` (aria-label "Column management"),
enumerated from the live DOM on 2026-08-01 — not recalled, and not guessed from a class name.

ONE SIDE EFFECT, AND IT IS THE LAB'S OWN. Console column choices persist per user (they are stored
in that user's console user-settings), so after this runs, that attendee slot keeps the Node column
on its Pods list. That is precisely what the lab's exercise 1 tells the attendee to do, so the
end state matches the page rather than contradicting it. Nothing else here mutates anything: the
cluster is only ever read.

    KUBECONFIG=~/.kube/<cluster>.config tools/media/.venv/bin/python \
      tools/media/capture_m17_pods_by_node.py \
        --domain apps.cluster-<id>.<base> --profile tools/media/shot-profile-user7 --user user7
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from playwright.sync_api import Error as PWError
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# Reuse, never re-implement: the overlay dismissal and the session cache are the two things that
# have silently ruined captures on this project, and there must be exactly one copy of each.
import capture as cap  # noqa: E402

VIEWPORT = {"width": 1600, "height": 1100}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", required=True, type=Path)
    ap.add_argument("--user", default="user7")
    ap.add_argument("--domain", default=os.environ.get("OGSR_DOMAIN", ""))
    ap.add_argument("--out-root", type=Path, default=cap.ASSETS)
    args = ap.parse_args()
    if not args.domain:
        return err("set --domain or $OGSR_DOMAIN")

    slug = "deployment-targets-scheduling"
    out = args.out_root / slug / f"{slug}-01-pods-by-node.png"
    if out.exists():
        # Same clobber guard as capture.py, and for the same reason: these shots are
        # state-dependent, so a re-run does not reproduce the picture, it replaces it with
        # whatever the lab looks like now. Delete the file deliberately to re-shoot.
        return err(f"{out} already exists — delete it deliberately to re-shoot")

    url = (f"https://console-openshift-console.{args.domain}"
           f"/k8s/ns/{args.user}-dev/pods")

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(args.profile), channel="chrome", headless=True, viewport=VIEWPORT,
            ignore_https_errors=True, locale="en-US",
            args=["--no-first-run", "--no-default-browser-check"],
        )
        sess = cap.session_file(args.profile)
        n = cap.load_session(ctx, sess)
        print(f"  restored {n} cached cookies")
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        try:
            page.goto(url, wait_until="domcontentloaded", timeout=60_000)
            page.wait_for_timeout(2000)
            cap.dismiss_overlays(page)

            who = cap.console_identity(page)
            if who != args.user:
                # The single most expensive failure this directory has: a dead or wrong session
                # writes a perfectly valid PNG of a login chooser or someone else's namespace, and
                # the run reports success. Ask the API who this is before spending anything else.
                return err(f"session is {who!r}, not {args.user!r} — refusing to shoot")

            page.wait_for_function(
                "() => !!document.body && document.body.innerText.includes('parasol-claims')",
                timeout=60_000)

            # --- the three steps a jobs file cannot express -------------------------------
            page.click('button[data-test="manage-columns"]', timeout=15_000)
            page.wait_for_selector('[role="dialog"]', timeout=15_000)
            page.wait_for_timeout(800)

            # Exact label match, not a substring: the dialog lists every available column and
            # several contain "Node" inside longer words in other resource types. `check()` is
            # idempotent — it is a no-op if the box is already ticked, which matters because the
            # preference persists and this may not be the first run against this profile.
            box = page.get_by_role("checkbox", name="Node", exact=True)
            box.check(timeout=15_000)

            save = page.get_by_role("button", name="Save", exact=True)
            save.click(timeout=15_000)
            page.wait_for_selector('[role="dialog"]', state="detached", timeout=15_000)

            # Prove the column ARRIVED, in the table, before shooting. "I clicked Save" is not the
            # same claim as "the table has a Node column", and only the second one protects the
            # shot — the same distinction dismiss_overlays() draws.
            #
            # `includes`, not `===`: a header cell is not just its label. Measured 2026-08-01 — an
            # exact match timed out for 30s on a table that was visibly showing the column, because
            # each `th` also contains a sort control and a resize handle, so its innerText carries
            # more than the word. No other Pods column name contains "Node", so this stays specific.
            try:
                page.wait_for_function(
                    """() => [...document.querySelectorAll('th')]
                            .some(t => (t.innerText || '').includes('Node'))""",
                    timeout=30_000)
            except PWError:
                heads = page.evaluate(
                    "() => [...document.querySelectorAll('th')].map(t => (t.innerText||'').trim())")
                return err(f"no Node column after Save — headers are {heads}")
            page.wait_for_timeout(3000)

            left = cap.dismiss_overlays(page)
            if left:
                return err("console overlay still covering the page: " + ", ".join(left))

            body = page.evaluate("() => document.body.innerText")
            for bad in ("Access restricted", "An error occurred", "Log in with"):
                if bad in body:
                    return err(f"page shows {bad!r} — refusing to shoot a broken view")

            # The caption promises DIFFERENT values in the Node column. Assert the spread from the
            # rendered table itself, not from the API: the API being right is what got the failed
            # job to this point in the first place.
            nodes = page.evaluate(
                """() => {
                    const ths = [...document.querySelectorAll('th')];
                    // Same `includes` as the wait above, and for the same measured reason: a `th`
                    // carries its sort and resize controls too, so an exact match finds nothing and
                    // this silently returns an empty column.
                    const i = ths.findIndex(t => (t.innerText || '').includes('Node'));
                    if (i < 0) return [];
                    return [...document.querySelectorAll('tbody tr')].map(r => {
                        const c = r.children[i];
                        return c ? (c.innerText || '').trim() : '';
                    }).filter(Boolean);
                }""")
            distinct = sorted(set(nodes))
            print(f"  Node column values: {nodes}")
            if len(distinct) < 2:
                return err(f"Node column shows {len(distinct)} distinct node(s) — the shot is "
                           f"supposed to show pods SPREAD across nodes")

            misses = [(t, why) for t, why in
                      page.evaluate(cap._IN_FRAME,  # noqa: SLF001 - one harness, one definition
                                    {"needles": ["Node", "parasol-claims", "statement-batch"],
                                     "full": False}) if why]
            if misses:
                return err("not in frame: " + "; ".join(f"{t!r} {why}" for t, why in misses))

            out.parent.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(out))
            print(f"OK   {slug}/{out.name}  [{out.stat().st_size // 1024} KB]")
        except PWError as exc:
            return err(f"{type(exc).__name__}: {str(exc).splitlines()[0][:200]}")
        finally:
            cap.save_session(ctx, sess)
            ctx.close()
    return 0


def err(msg: str) -> int:
    print(f"FAIL {msg}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
