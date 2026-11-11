/*
 * click-to-run.js — click any `role=execute` code block to send its command straight into the
 * cockpit terminal, so attendees never copy-paste. Matches the RHDP guided showroom (owner,
 * 2026-11-12): no button sitting on top of the code; the block itself is the target, and the theme's
 * hover toolbar reads `kind | copy | run`. Selecting text inside the block still copies (it does not
 * run), and Tab + Enter/Space runs it from the keyboard. Adapted from the old
 * getting-started / agentops-showroom supplemental-ui buttons.js (the mechanism the project owner
 * pointed at, 2026-07-11); the nookbag + rhdp theme we run ship copy only, never a run button.
 *
 * How it works: this runs INSIDE the content iframe (nookbag renders content in an iframe). It makes
 * each `.listingblock.execute` clickable; on click it finds the terminal iframe in the nookbag
 * parent (same-origin — nginx proxies content + terminal under one host), postMessages the command
 * to it, and injects a one-time listener into the terminal iframe that writes the command to ttyd's
 * xterm (window.term / window.client.sendData). Default target is Terminal 1 (/tty-top); a block
 * tagged `role="execute send-to-tty-bottom"` targets Terminal 2 instead.
 */
(function () {
  'use strict';

  var DEFAULT_PATH = '/tty-top'; // Terminal 1 (the primary "act" terminal in our double-terminal)

  function targetPathFor(block) {
    var cls = Array.from(block.classList).find(function (c) { return /^send-to-.+/.test(c); });
    return cls ? '/' + cls.replace('send-to-', '') : DEFAULT_PATH;
  }

  function commandText(listing) {
    var code = listing.querySelector('pre code, pre');
    return (code ? code.textContent : listing.textContent).replace(/ /g, ' ').trim();
  }

  var RUN_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 2.5v11a.5.5 0 00.77.42l8.5-5.5a.5.5 0 000-.84l-8.5-5.5A.5.5 0 004 2.5z"/></svg>';

  // The theme builds its hover toolbar (.source-toolbox: language | copy) in its own script, possibly
  // after ours, so this is retried on every scan until the toolbar exists.
  function addToolboxRun(listing, target, path) {
    if (listing.dataset.ctrToolbox) return;
    var toolbox = listing.querySelector('.source-toolbox');
    if (!toolbox) return;
    listing.dataset.ctrToolbox = 'true';
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'ctr-run-button';
    b.title = 'Run in terminal';
    b.setAttribute('aria-label', 'Run in terminal');
    b.innerHTML = RUN_ICON;
    b.addEventListener('click', function () { sendToTerminal(commandText(listing), target, path); });
    toolbox.appendChild(b);
  }

  function makeClickable() {
    document.querySelectorAll('.listingblock.execute').forEach(function (listing) {
      var pre = listing.querySelector('pre') || listing;
      addToolboxRun(listing, pre, targetPathFor(listing));
      if (listing.dataset.ctrReady) return;
      listing.dataset.ctrReady = 'true';
      var path = targetPathFor(listing);
      var target = listing.querySelector('pre') || listing;
      target.classList.add('ctr-run');
      target.setAttribute('tabindex', '0');
      target.setAttribute('role', 'button');
      target.setAttribute('title', 'Click to run in the terminal');
      target.setAttribute('aria-label', 'Run this command in the terminal');
      target.addEventListener('click', function (ev) {
        if (ev.target.closest('button, a')) return;            // the theme's copy icon, links
        var sel = window.getSelection && window.getSelection();
        if (sel && String(sel).length > 0) return;              // selecting text to copy, not running
        sendToTerminal(commandText(listing), target, path);
      });
      target.addEventListener('keydown', function (ev) {
        if (ev.key !== 'Enter' && ev.key !== ' ') return;
        ev.preventDefault();
        sendToTerminal(commandText(listing), target, path);
      });
    });
  }

  function findTerminalFrame(targetPath) {
    try {
      if (!window.parent || window.parent === window) return null;
      var frames = window.parent.document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        if ((frames[i].getAttribute('src') || '').indexOf(targetPath) !== -1) return frames[i];
      }
    } catch (e) { /* cross-origin (shouldn't happen — same host) */ }
    return null;
  }

  // Injected once into the terminal iframe: receives {type:'execute'} and writes to ttyd's xterm.
  var LISTENER = [
    '(function(){',
    '  if (window.__ctrInstalled) return; window.__ctrInstalled = true;',
    '  window.addEventListener("message", function(ev){',
    '    if (!ev.data || ev.data.type !== "execute") return;',
    '    var cmd = String(ev.data.data).replace(/[\\r\\n]+$/, "");',
    '    var t = window.term;',
    '    if (window.client && typeof window.client.sendData === "function") { window.client.sendData(cmd + "\\r"); return; }',
    '    if (t && t._core && t._core.coreService && t._core.coreService._inputHandler) {',
    '      for (var i=0;i<cmd.length;i++){ t._core.coreService._inputHandler.parse(cmd[i]); }',
    '      t._core.coreService._inputHandler.parse("\\r"); return;',
    '    }',
    '    if (t && t._core && t._core._onData) { t._core._onData.fire(cmd + "\\r"); return; }',
    '    if (t) { t.write(cmd + "\\r\\n"); }',
    '  }, false);',
    '})();'
  ].join('\n');

  function ensureListener(frame) {
    if (frame.dataset.ctrListener) return;
    try {
      var doc = frame.contentWindow.document;
      var s = doc.createElement('script');
      s.textContent = LISTENER;
      doc.body.appendChild(s);
      frame.dataset.ctrListener = 'true';
    } catch (e) { /* terminal not ready yet — will retry on next click */ }
  }

  function sendToTerminal(command, el, targetPath) {
    var frame = findTerminalFrame(targetPath);
    if (!frame || !frame.contentWindow) {
      // Terminal tab not open yet: fall back to clipboard so the attendee is never stuck.
      if (navigator.clipboard) navigator.clipboard.writeText(command);
      flash(el, 'Copied: no terminal here', 2600);
      return;
    }
    ensureListener(frame);
    frame.contentWindow.postMessage({ type: 'execute', data: command + '\r' }, '*');
    flash(el, '✓ Sent to terminal', 1600);
  }

  function flash(el, text, ms) {             // a label on the block itself (CSS ::after), then gone
    el.setAttribute('data-ctr-msg', text);
    el.classList.add('ctr-run--sent');
    clearTimeout(el._ctrTimer);
    el._ctrTimer = setTimeout(function () { el.classList.remove('ctr-run--sent'); }, ms);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', makeClickable);
  } else {
    makeClickable();
  }
  // Antora tabs / late DOM: re-scan a couple of times so blocks inside tab panels are clickable too.
  setTimeout(makeClickable, 400);
  setTimeout(makeClickable, 1200);
})();
