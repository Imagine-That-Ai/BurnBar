(() => {
  'use strict';

  const target = document.getElementById('zoom-offset-target');
  const button = document.getElementById('zoom-offset-button');
  const status = document.getElementById('zoom-offset-status');
  document.body.style.zoom = '1.25';

  requestAnimationFrame(() => {
    window.scrollTo({ left: 480, top: 720, behavior: 'auto' });
    document.body.dataset.initialOffsetApplied = 'true';
  });

  button.addEventListener('click', (event) => {
    const box = target.getBoundingClientRect();
    status.textContent = `Fresh box left=${Math.round(box.left)}, top=${Math.round(box.top)}, trusted=${String(event.isTrusted)}.`;
    status.dataset.verified = 'true';
  });
})();
