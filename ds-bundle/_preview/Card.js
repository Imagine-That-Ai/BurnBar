var __dsPreview = (() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __esm = (fn, res, err) => function __init() {
    if (err) throw err[0];
    try {
      return fn && (res = (0, fn[__getOwnPropNames(fn)[0]])(fn = 0)), res;
    } catch (e) {
      throw err = [e], e;
    }
  };
  var __commonJS = (cb, mod) => function __require() {
    try {
      return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
    } catch (e) {
      throw mod = 0, e;
    }
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __reExport = (target, mod, secondTarget) => (__copyProps(target, mod, "default"), secondTarget && __copyProps(secondTarget, mod, "default"));
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // <define:import.meta.env>
  var init_define_import_meta_env = __esm({
    "<define:import.meta.env>"() {
    }
  });

  // ds-raw:__ds_raw__
  var require_ds_raw = __commonJS({
    "ds-raw:__ds_raw__"(exports, module) {
      init_define_import_meta_env();
      module.exports = window.OpenBurnBarConsole;
    }
  });

  // shim:react-shim
  var require_react_shim = __commonJS({
    "shim:react-shim"(exports, module) {
      init_define_import_meta_env();
      var R = window.React;
      function jsx2(t, p, k) {
        return R.createElement(t, k === void 0 ? p : Object.assign({ key: k }, p));
      }
      module.exports = R;
      module.exports.jsx = jsx2;
      module.exports.jsxs = jsx2;
      module.exports.jsxDEV = jsx2;
      module.exports.Fragment = R.Fragment;
    }
  });

  // .design-sync/previews/Card.tsx
  var Card_exports = {};
  __export(Card_exports, {
    Basic: () => Basic,
    WithMeter: () => WithMeter
  });
  init_define_import_meta_env();

  // ds-shim:ds
  var ds_exports = {};
  __export(ds_exports, {
    default: () => ds_default
  });
  init_define_import_meta_env();
  __reExport(ds_exports, __toESM(require_ds_raw()));
  var g = window.OpenBurnBarConsole;
  var ds_default = "default" in g ? g.default : g;

  // .design-sync/previews/Card.tsx
  var import_jsx_runtime = __toESM(require_react_shim());
  var Basic = () => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(ds_exports.Card, { style: { maxWidth: 380 }, children: [
    /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(ds_exports.CardHeader, { children: [
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ds_exports.CardTitle, { children: "Pensieve" }),
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ds_exports.CardDescription, { children: "Your connected repositories and recall sources." })
    ] }),
    /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ds_exports.CardContent, { children: /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", { style: { margin: 0, fontSize: 14, color: "var(--color-text-base)" }, children: "3 repositories indexed · last recall 2h ago" }) })
  ] });
  var WithMeter = () => /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(ds_exports.Card, { style: { maxWidth: 380 }, children: [
    /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(ds_exports.CardHeader, { children: [
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ds_exports.CardTitle, { children: "Encrypted vault" }),
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ds_exports.CardDescription, { children: "Storage used this billing cycle." })
    ] }),
    /* @__PURE__ */ (0, import_jsx_runtime.jsxs)(ds_exports.CardContent, { children: [
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)(ds_exports.Progress, { value: 0.62 }),
      /* @__PURE__ */ (0, import_jsx_runtime.jsx)("p", { style: { margin: "10px 0 0", fontSize: 13, color: "var(--color-text-mute)" }, children: "6.2 GB of 10 GB" })
    ] })
  ] });
  return __toCommonJS(Card_exports);
})();
