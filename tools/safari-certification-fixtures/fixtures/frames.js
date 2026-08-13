(() => {
  'use strict';
  const status = document.getElementById('frame-status');
  const frames = [
    document.getElementById('same-origin-frame'),
    document.getElementById('cross-origin-frame')
  ];
  let loaded = 0;
  for (const frame of frames) {
    frame.addEventListener('load', () => {
      loaded += 1;
      status.textContent = `${loaded} of 2 child frames loaded.`;
      status.dataset.loaded = String(loaded);
    });
  }
})();
