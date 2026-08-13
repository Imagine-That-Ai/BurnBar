(() => {
  'use strict';
  const action = document.getElementById('owned-child-action');
  const status = document.getElementById('owned-tab-status');
  if (action && status) {
    action.addEventListener('click', (event) => {
      status.textContent = `Owned-child action verified; trusted=${String(event.isTrusted)}.`;
      status.dataset.verified = 'true';
    });
  }
})();
