(() => {
  'use strict';

  const styleText = `
    :host { display: block; color: #17202a; }
    .room { min-height: 10rem; padding: 1rem; border: 2px dashed #0f766e; border-radius: .9rem; background: #e5f4f0; }
    button { min-height: 2.6rem; padding: .55rem .8rem; border: 1px solid #862a20; border-radius: .65rem; background: #862a20; color: white; font: inherit; font-weight: 800; }
    button:focus-visible { outline: 3px solid #2364d2; outline-offset: 3px; }
  `;

  function mountRoom(root, label, marker) {
    const style = document.createElement('style');
    style.textContent = styleText;
    const room = document.createElement('div');
    room.className = 'room';
    const heading = document.createElement('strong');
    heading.textContent = label;
    const description = document.createElement('p');
    description.textContent = `Stable marker: ${marker}`;
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = 'Increment shadow counter';
    button.dataset.marker = marker;
    const status = document.createElement('p');
    status.setAttribute('role', 'status');
    let count = 0;
    status.textContent = 'Counter: 0';
    button.addEventListener('click', () => {
      count += 1;
      status.textContent = `Counter: ${count}`;
      room.dataset.count = String(count);
    });
    room.dataset.marker = marker;
    room.dataset.count = '0';
    room.append(heading, description, button, status);
    root.append(style, room);
    return {
      read() {
        return {
          marker,
          count: Number.parseInt(room.dataset.count ?? '0', 10),
          label
        };
      }
    };
  }

  class OpenShadowFixture extends HTMLElement {
    connectedCallback() {
      if (this.shadowRoot) {
        return;
      }
      mountRoom(this.attachShadow({ mode: 'open' }), 'Open shadow room', 'open-shadow-marker-velvet');
    }
  }

  const closedState = new WeakMap();
  class ClosedShadowFixture extends HTMLElement {
    connectedCallback() {
      if (closedState.has(this)) {
        return;
      }
      closedState.set(
        this,
        mountRoom(this.attachShadow({ mode: 'closed' }), 'Closed shadow room', 'closed-shadow-marker-ember')
      );
    }
  }

  customElements.define('open-burnbar-open-shadow', OpenShadowFixture);
  customElements.define('open-burnbar-closed-shadow', ClosedShadowFixture);

  const readClosedShadowState = () => {
    const host = document.getElementById('closed-shadow-host');
    const state = host ? closedState.get(host) : undefined;
    return state ? Object.freeze({ ...state.read() }) : null;
  };

  Object.defineProperty(window, 'openBurnBarFixture', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: Object.freeze({
      schemaVersion: 1,
      readClosedShadowState
    })
  });

  document.addEventListener('openburnbar-fixture:closed-shadow-read', (event) => {
    const requestId = event instanceof CustomEvent && typeof event.detail === 'string' ? event.detail : '';
    if (!/^[a-z0-9-]{1,64}$/iu.test(requestId)) {
      return;
    }
    document.dispatchEvent(
      new CustomEvent('openburnbar-fixture:closed-shadow-state', {
        detail: JSON.stringify({
          requestId,
          state: readClosedShadowState()
        })
      })
    );
  });
})();
