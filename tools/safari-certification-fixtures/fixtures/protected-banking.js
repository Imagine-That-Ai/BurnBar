(() => {
  'use strict';
  const form = document.getElementById('protected-form');
  const status = document.getElementById('protected-status');
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    form.reset();
    status.textContent =
      'Fixture submission blocked locally. All entered demonstration values were cleared and nothing was transmitted.';
    status.dataset.submissionBlocked = 'true';
  });
})();
