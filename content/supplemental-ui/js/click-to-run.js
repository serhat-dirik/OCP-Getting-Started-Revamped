/*
 * click-to-run.js — routes the theme's "Run in terminal" button to the cockpit's ttyd terminals.
 *
 * The RHDP showroom theme (v2.0.3+, the same bundle the owner's other workshops use) builds the
 * hover toolbar on every code block itself — `kind | copy | run` — with its own icons, "Executed!"
 * toast and styling. Its run button looks for the terminal in RHDP's guided-showroom layout
 * (`.tabcontent.active .main-content`), which our nookbag cockpit does not have, so on its own it
 * would only ever say "Not executed!". This file takes the click first (capture phase, so the
 * theme's handler never runs) and sends the command to our terminal instead. Styling stays the
 * theme's: success and failure reuse its `clicked` / `error` classes and its toast element.
 *
 * Routing: this runs INSIDE the content iframe. It finds the terminal iframe in the nookbag parent
 * (same-origin — nginx proxies content + terminal under one host), postMessages the command to it,
 * and injects a one-time listener into that frame that writes the command to ttyd's xterm. Default
 * target is Terminal 1 (/tty-top); a block tagged `role="execute send-to-tty-bottom"` goes to
 * Terminal 2. With no terminal at all (the standalone Pages site) the command is copied instead.
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
    return (code ? code.textContent : listing.textContent).replace(/\u00a0/g, ' ').replace(/ +$/gm, '').trim();
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

  // The theme's own toast: `clicked` shows it, `error` turns it into the failure style.
  function toast(button, text, isError) {
    var t = button.querySelector('.paste-toast');
    if (t) t.textContent = text;
    button.classList.add('clicked');
    if (isError) button.classList.add('error');
    requestAnimationFrame(function () {
      requestAnimationFrame(function () {
        button.classList.remove('clicked');
        setTimeout(function () { button.classList.remove('error'); if (t) t.textContent = 'Executed!'; }, 1100);
      });
    });
  }

  document.addEventListener('click', function (ev) {
    var button = ev.target.closest && ev.target.closest('.paste-button');
    if (!button) return;
    var listing = button.closest('.listingblock');
    if (!listing) return;
    ev.stopPropagation();          // capture phase: the theme's own handler never runs
    ev.preventDefault();
    var command = commandText(listing);
    var frame = findTerminalFrame(targetPathFor(listing));
    if (!frame || !frame.contentWindow) {
      // No terminal here (standalone site): copy instead. A browser can refuse the clipboard (page
      // not focused, no permission); say so with the theme's failure toast rather than throw.
      if (!navigator.clipboard) { toast(button, 'Not executed!', true); return; }
      navigator.clipboard.writeText(command).then(function () { toast(button, 'Copied!', false); },
                                                  function () { toast(button, 'Not executed!', true); });
      return;
    }
    ensureListener(frame);
    frame.contentWindow.postMessage({ type: 'execute', data: command + '\r' }, '*');
    toast(button, 'Executed!', false);
  }, true);
})();
