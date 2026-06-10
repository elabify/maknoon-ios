// Maknoon mini-app provider shim. Injected at document start by the
// native host into every mini app's WebView. It is host-supplied glue,
// not a published SDK (per ADR-0018): it only marshals calls to the
// native bridge and back. All trust-critical work happens natively.
//
// Two providers are exposed:
//   * window.ethereum  -- EIP-1193, pinned to Sepolia, for crypto.
//   * window.maknoon   -- bespoke identity/credentials provider.
//
// The native message handler is registered with a reply handler, so
// `postMessage(...)` returns a Promise that resolves with our envelope
// { ok, result } | { ok, error: { code, message } }.

(function () {
  "use strict";

  function call(namespace, method, params) {
    var bridge = window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.maknoonBridge;
    if (!bridge) {
      return Promise.reject(makeError(-32603, "Maknoon bridge unavailable"));
    }
    return bridge
      .postMessage({ namespace: namespace, method: method, params: params || null })
      .then(function (env) {
        if (env && env.ok) return env.result;
        var e = (env && env.error) || { code: -32603, message: "Unknown bridge error" };
        return Promise.reject(makeError(e.code, e.message));
      });
  }

  function makeError(code, message) {
    var err = new Error(message || "Request failed");
    err.code = code;
    return err;
  }

  // --- minimal event emitter (chainChanged / accountsChanged) ---------
  function Emitter() { this._l = {}; }
  Emitter.prototype.on = function (ev, fn) {
    (this._l[ev] = this._l[ev] || []).push(fn);
    return this;
  };
  Emitter.prototype.removeListener = function (ev, fn) {
    var a = this._l[ev]; if (!a) return this;
    this._l[ev] = a.filter(function (f) { return f !== fn; });
    return this;
  };
  Emitter.prototype.emit = function (ev, payload) {
    (this._l[ev] || []).slice().forEach(function (fn) {
      try { fn(payload); } catch (e) { /* swallow listener errors */ }
    });
  };

  // --- window.ethereum (EIP-1193) -------------------------------------
  var ethEmitter = new Emitter();
  var ethereum = {
    isMaknoon: true,
    // request({ method, params }) -> Promise
    request: function (args) {
      if (!args || typeof args.method !== "string") {
        return Promise.reject(makeError(-32602, "request requires a method"));
      }
      return call("eth", args.method, args.params);
    },
    on: function (ev, fn) { ethEmitter.on(ev, fn); return ethereum; },
    removeListener: function (ev, fn) { ethEmitter.removeListener(ev, fn); return ethereum; },
    // Legacy convenience.
    enable: function () { return ethereum.request({ method: "eth_requestAccounts" }); },
  };

  // --- window.maknoon (identity + storage + helpers) ------------------
  var maknoon = {
    version: 1,
    identity: {
      // request(options): same-device disclosure -> { decision, checks, disclosed }
      request: function (options) { return call("maknoon", "identity.request", options || {}); },
      // collect(options): cross-device — scan + verify a SEPARATE customer's
      // credential. -> { decision, reason, schema, disclosed, checks, offline }
      collect: function (options) { return call("maknoon", "identity.collect", options || {}); },
      getDID: function () { return call("maknoon", "identity.getDID", null); },
    },
    // Durable, per-app, encrypted-backup-backed key-value settings.
    // NOTE: these are ASYNC (return Promises), unlike localStorage. The
    // WebView's own localStorage is ephemeral; use this for anything that
    // must survive relaunch or restore.
    storage: {
      getItem: function (key) { return call("storage", "storage.get", { key: key }); },
      setItem: function (key, value) { return call("storage", "storage.set", { key: key, value: String(value) }); },
      removeItem: function (key) { return call("storage", "storage.remove", { key: key }); },
      keys: function () { return call("storage", "storage.keys", null); },
    },
    // Read the user's saved addresses for a chain (own wallets + contacts).
    // Requires the "payment" permission. -> [{name,address,network,isOwnWallet}]
    addressBook: {
      list: function (opts) { return call("addressBook", "addressBook.list", opts || {}); },
    },
    // Public market data: configured fiat + native-coin spot rate.
    // quote({chain, network?}) -> { fiatCode, ticker, coinId, rate|null }
    fiat: {
      quote: function (opts) { return call("fiat", "fiat.quote", opts || {}); },
    },
    // Receive a payment: opens a native QR + on-chain watcher. Requires the
    // "payment" permission. receive({chain,network,address,amount,fiatText?})
    // -> { txHash|null, chain, network, amount, confirmedAt }
    payment: {
      receive: function (opts) { return call("payment", "payment.receive", opts || {}); },
      // List the user's Lightning accounts -> [{ id, label }] (requires "payment").
      lightningAccounts: function () { return call("payment", "payment.lightningAccounts", null); },
    },
    // Host context + a Face ID gate for the dApp's own sensitive screens.
    device: {
      info: function () { return call("device", "device.info", null); },              // {theme,locale,fiatCode,appVersion}
      authenticate: function (reason) { return call("device", "device.authenticate", { reason: reason }); }, // {ok}
    },
    // Haptic feedback: "success"|"warning"|"error"|"light"|"medium"|"heavy".
    haptic: function (kind) { return call("haptic", "haptic.fire", { kind: kind }); },
    // Write-only clipboard (requires "clipboard").
    clipboard: {
      write: function (text) { return call("clipboard", "clipboard.write", { text: String(text) }); },
    },
    // System share sheet (requires "share").
    share: {
      text: function (text) { return call("share", "share.text", { text: String(text) }); },
      file: function (fileName, text) { return call("share", "share.file", { fileName: fileName, text: String(text) }); },
    },
    // Read the user's own wallet addresses for a chain (requires "wallet").
    // getAccounts({chain}) -> [{ name, address, network }]
    wallet: {
      getAccounts: function (opts) { return call("wallet", "wallet.getAccounts", opts || {}); },
    },
    // Native QR/barcode scanner (requires "scan"). scan({prompt?}) -> { value }
    scan: function (opts) { return call("scan", "scan.read", opts || {}); },
    // Unified Verify & Pay (ADR-0031, requires "payment"): one native sheet
    // hosts a single QR carrying BOTH the identity request and the payment
    // terms; the customer scans it and completes a single confirm (disclose +
    // sign + broadcast). collectAndCharge({ identity, payment, lane }) ->
    // { decision, reason, missing, message, disclosed, txHash }
    commerce: {
      collectAndCharge: function (opts) { return call("commerce", "collectAndCharge", opts || {}); },
    },
    // Per-install merchant verifier identity, so a merchant dApp can render its
    // own settings (name + receipts are the dApp's own via storage).
    // getIdentity() -> { did, publicKey, verified }
    merchant: {
      getIdentity: function () { return call("merchant", "merchant.getIdentity", null); },
    },
  };

  Object.defineProperty(window, "ethereum", { value: ethereum, configurable: false, writable: false });
  Object.defineProperty(window, "maknoon", { value: maknoon, configurable: false, writable: false });

  // Native pushes events here via evaluateJavaScript.
  window.__maknoonEmit = function (kind, ev, payload) {
    if (kind === "eth") ethEmitter.emit(ev, payload);
  };

  // Let the page know the providers are ready (EIP-1193 / EIP-6963 style).
  try {
    window.dispatchEvent(new Event("ethereum#initialized"));
    window.dispatchEvent(new Event("maknoon#initialized"));
  } catch (e) { /* older webviews */ }
})();
