/*
 * lightbox.js — click any diagram (Mermaid SVG or an image) to enlarge it in a full-window overlay.
 * CC-5 (project-owner review 2026-07): several diagrams read too small, worst in the narrow cockpit
 * instructions panel. Like click-to-run.js this runs INSIDE the content iframe, but the overlay is
 * appended to the TOP document — window.parent in the cockpit (same-origin, the mechanism
 * click-to-run.js already relies on) so it covers the whole cockpit rather than just the content
 * panel, or this document on the standalone site. The overlay is styled inline, so it needs no CSS
 * in whichever document hosts it. The in-flow zoom-in affordance lives in head-styles.hbs.
 */
(function () {
  'use strict';

  // Where the overlay is mounted: the cockpit's top frame (same-origin) when we're framed, else this
  // document (standalone site). Fall back to this document if the parent is somehow cross-origin.
  function hostDocument() {
    try {
      if (window.parent && window.parent !== window && window.parent.document) return window.parent.document;
    } catch (e) { /* cross-origin — shouldn't happen (one host); fall through */ }
    return document;
  }

  var overlay = null;
  var keyHandler = null;

  function close() {
    if (keyHandler) { hostDocument().removeEventListener('keydown', keyHandler); keyHandler = null; }
    if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
    overlay = null;
  }

  function open(node) {
    var doc = hostDocument();
    close();

    overlay = doc.createElement('div');
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-label', 'Enlarged diagram — click or press Escape to close');
    overlay.style.cssText = [
      'position:fixed', 'inset:0', 'z-index:2147483000',
      'display:flex', 'align-items:center', 'justify-content:center',
      'background:rgba(0,0,0,0.82)', 'padding:2.5vmin', 'cursor:zoom-out'
    ].join(';');

    var stage = doc.createElement('div');
    stage.style.cssText = [
      'background:#fff', 'border-radius:6px', 'padding:1.25rem',
      'max-width:96vw', 'max-height:94vh', 'overflow:auto',
      'box-shadow:0 10px 40px rgba(0,0,0,0.5)', 'cursor:default'
    ].join(';');

    // Clone so the in-flow diagram is untouched, then size it to fill the overlay. An inline SVG
    // needs an explicit pixel box computed from its viewBox aspect — width:auto collapses it to
    // zero — while a raster image sizes fine from its intrinsic dimensions under max-width/height.
    var win = doc.defaultView || window;
    var maxW = 0.92 * win.innerWidth, maxH = 0.88 * win.innerHeight;
    var clone = node.cloneNode(true);
    if (node.tagName && node.tagName.toLowerCase() === 'svg') {
      var vb = node.viewBox && node.viewBox.baseVal;
      var box = node.getBoundingClientRect();
      var aspect = (vb && vb.width && vb.height) ? vb.width / vb.height
                 : (box.width && box.height) ? box.width / box.height : 1.6;
      var w, h;
      if (maxW / maxH > aspect) { h = maxH; w = h * aspect; } else { w = maxW; h = w / aspect; }
      clone.removeAttribute('width'); clone.removeAttribute('height');
      clone.style.maxWidth = 'none';
      clone.style.width = Math.round(w) + 'px';
      clone.style.height = Math.round(h) + 'px';
    } else {
      clone.style.width = 'auto'; clone.style.height = 'auto';
      clone.style.maxWidth = '92vw'; clone.style.maxHeight = '88vh';
    }
    stage.appendChild(clone);
    overlay.appendChild(stage);

    // Backdrop click or Escape closes; a click on the diagram itself does not.
    overlay.addEventListener('click', close);
    stage.addEventListener('click', function (e) { e.stopPropagation(); });
    keyHandler = function (e) { if (e.key === 'Escape') close(); };
    doc.addEventListener('keydown', keyHandler);

    doc.body.appendChild(overlay);
  }

  // Event delegation in the content document: a click on a diagram opens the overlay.
  document.addEventListener('click', function (e) {
    if (e.target.closest('.run-in-terminal-btn')) return; // never hijack the ▶ Run button
    var mermaid = e.target.closest('.doc .imageblock .mermaid');
    if (mermaid) {
      var svg = mermaid.querySelector('svg');
      if (svg) { e.preventDefault(); open(svg); }
      return;
    }
    var img = e.target.closest('.doc .imageblock img');
    if (img) { e.preventDefault(); open(img); }
  });
})();
