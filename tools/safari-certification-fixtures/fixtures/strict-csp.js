(() => {
  'use strict';
  const button = document.getElementById('strict-csp-button');
  const status = document.getElementById('strict-csp-status');
  button.addEventListener('click', (event) => {
    status.textContent = `Strict-CSP interaction observed; trusted=${String(event.isTrusted)}.`;
    status.dataset.confirmed = 'true';
  });
})();
