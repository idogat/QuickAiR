// ╔══════════════════════════════════════╗
// ║  QuickAiR — 08_manifest.js            ║
// ║  Manifest panel init, placeholder    ║
// ║  auto-display on load                ║
// ╠══════════════════════════════════════╣
// ║  Reads    : DOM #placeholder          ║
// ║  Writes   : placeholder visibility    ║
// ║  Functions: init (IIFE)               ║
// ║  Depends  : 03_core.js               ║
// ║  Version  : 3.39                      ║
// ╚══════════════════════════════════════╝

// Initialize: auto-open file picker + show placeholder
(function init() {
  const ph = document.getElementById('placeholder');
  if (ph) ph.classList.add('show');
})();

