(() => {
  'use strict';

  const list = document.getElementById('infinite-list');
  const status = document.getElementById('infinite-status');
  const sentinel = document.getElementById('infinite-sentinel');
  const button = document.getElementById('infinite-more');
  const batchSize = 20;
  const maximumItems = 100;
  let count = 0;
  let loading = false;

  function loadBatch() {
    if (loading || count >= maximumItems) {
      return;
    }
    loading = true;
    const fragment = document.createDocumentFragment();
    const nextCount = Math.min(count + batchSize, maximumItems);
    for (let index = count + 1; index <= nextCount; index += 1) {
      const item = document.createElement('li');
      item.id = `harbor-record-${String(index).padStart(3, '0')}`;
      item.dataset.sequence = String(index);
      const heading = document.createElement('strong');
      heading.textContent = `Harbor record ${String(index).padStart(3, '0')}`;
      const detail = document.createElement('p');
      detail.textContent = `Deterministic cargo index ${index * 7}; inspection lane ${(index % 4) + 1}.`;
      item.append(heading, detail);
      fragment.append(item);
    }
    list.append(fragment);
    count = nextCount;
    status.textContent =
      count === maximumItems
        ? `All ${count} deterministic records loaded.`
        : `${count} deterministic records loaded.`;
    status.dataset.count = String(count);
    button.disabled = count === maximumItems;
    loading = false;
  }

  button.addEventListener('click', loadBatch);
  const observer = new IntersectionObserver(
    (entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        loadBatch();
      }
    },
    { rootMargin: '240px 0px' }
  );
  observer.observe(sentinel);
  loadBatch();
})();
