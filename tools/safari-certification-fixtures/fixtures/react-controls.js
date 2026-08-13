(() => {
  'use strict';

  const React = window.React;
  const ReactDOM = window.ReactDOM;
  if (!React || !ReactDOM) {
    document.getElementById('react-root').textContent = 'React fixture runtime failed to load.';
    return;
  }

  const { createElement: h, useMemo, useState } = React;

  function ControlledFixture() {
    const [query, setQuery] = useState('Copper beacon');
    const [harbor, setHarbor] = useState('north');
    const [events, setEvents] = useState([]);

    const appendEvent = (kind, value, trusted) => {
      setEvents((current) => [
        ...current.slice(-7),
        `${kind}:${value}:trusted=${String(trusted)}`
      ]);
    };

    const summary = useMemo(
      () => `React state: query="${query}", harbor="${harbor}", events=${events.length}`,
      [events.length, harbor, query]
    );

    return h(
      'section',
      { className: 'panel', 'data-react-mounted': 'true' },
      h(
        'div',
        { className: 'control-grid' },
        h(
          'label',
          { htmlFor: 'react-query' },
          'Search phrase',
          h('input', {
            id: 'react-query',
            name: 'react-query',
            value: query,
            onInput: (event) => {
              setQuery(event.currentTarget.value);
              appendEvent('input', event.currentTarget.value, event.nativeEvent.isTrusted);
            },
            onChange: (event) => {
              setQuery(event.currentTarget.value);
              appendEvent('change', event.currentTarget.value, event.nativeEvent.isTrusted);
            }
          })
        ),
        h(
          'label',
          { htmlFor: 'react-harbor' },
          'Harbor',
          h(
            'select',
            {
              id: 'react-harbor',
              name: 'react-harbor',
              value: harbor,
              onInput: (event) => {
                setHarbor(event.currentTarget.value);
                appendEvent('select-input', event.currentTarget.value, event.nativeEvent.isTrusted);
              },
              onChange: (event) => {
                setHarbor(event.currentTarget.value);
                appendEvent('select-change', event.currentTarget.value, event.nativeEvent.isTrusted);
              }
            },
            h('option', { value: 'north' }, 'North harbor'),
            h('option', { value: 'central' }, 'Central harbor'),
            h('option', { value: 'south' }, 'South harbor')
          )
        ),
        h('p', { id: 'react-state', className: 'status', role: 'status' }, summary),
        h(
          'ol',
          { id: 'react-event-log', className: 'event-log', 'aria-label': 'React event log' },
          events.length === 0
            ? h('li', null, 'No control events observed.')
            : events.map((event, index) => h('li', { key: `${index}-${event}` }, event))
        )
      )
    );
  }

  ReactDOM.createRoot(document.getElementById('react-root')).render(h(ControlledFixture));
})();
