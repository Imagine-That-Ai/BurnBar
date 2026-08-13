# Vendored React fixture runtime

The two adjacent production files are unmodified upstream UMD artifacts from:

- `react@18.3.1/umd/react.production.min.js`
- `react-dom@18.3.1/umd/react-dom.production.min.js`

They are present only so `/react-controls` is an actual React-controlled form
without a package install, CDN, or runtime network request. Their exact bytes
are pinned by `../manifest.json` through the fixture asset manifest.

React is MIT licensed. The upstream license text is in `LICENSE.react.txt`.
