/*
 * click-to-run.js — a ▶ Run button on every `role=execute` code block that sends the command
 * straight into the cockpit terminal, so attendees never copy-paste. Adapted from the old
 * getting-started / agentops-showroom supplemental-ui buttons.js (the mechanism the project owner
 * pointed at, 2026-07-11); the nookbag + rhdp theme we run ship copy only, never a run button.
 *
 * How it works: this runs INSIDE the content iframe (nookbag renders content in an iframe). It adds
 * a ▶ button to each `.listingblock.execute`; on click it finds the terminal iframe in the nookbag
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

  function addButtons() {
    document.querySelectorAll('.listingblock.execute').forEach(function (listing) {
      if (listing.dataset.runButtonAdded) return;
      listing.dataset.runButtonAdded = 'true';
      var path = targetPathFor(listing);

      var btn = document.createElement('button');
      btn.className = 'run-in-terminal-btn';
      btn.type = 'button';
      btn.title = 'Run in the terminal';
      btn.setAttribute('aria-label', 'Run in the terminal');
      btn.innerHTML = '▶︎ Run';
      btn.addEventListener('click', function () { sendToTerminal(commandText(listing), btn, path); });
      listing.appendChild(btn);
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

  function sendToTerminal(command, btn, targetPath) {
    var frame = findTerminalFrame(targetPath);
    if (!frame || !frame.contentWindow) {
      // Terminal tab not open yet: fall back to clipboard so the attendee is never stuck.
      if (navigator.clipboard) navigator.clipboard.writeText(command);
      flash(btn, '⦻ Open the terminal tab', 2600);
      return;
    }
    ensureListener(frame);
    frame.contentWindow.postMessage({ type: 'execute', data: command + '\r' }, '*');
    flash(btn, '✓ Sent', 1600);
  }

  function flash(btn, text, ms) {
    var original = btn.innerHTML;
    btn.classList.add('run-in-terminal-btn--flash');
    btn.innerHTML = text;
    setTimeout(function () { btn.classList.remove('run-in-terminal-btn--flash'); btn.innerHTML = original; }, ms);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', addButtons);
  } else {
    addButtons();
  }
  // Antora tabs / late DOM: re-scan a couple of times so blocks inside tab panels also get the button.
  setTimeout(addButtons, 400);
  setTimeout(addButtons, 1200);
})();
