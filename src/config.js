(function (root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  } else {
    root.CABundleConfig = api;
  }
}(this, function () {
  "use strict";

  function encodeBase64(text) {
    return btoa(unescape(encodeURIComponent(text)));
  }

  function decodeBase64(text) {
    return decodeURIComponent(escape(atob(text || "")));
  }

  function buildSelection(state) {
    var customPath = state.custom ? String(state.customPath || "").trim() : "";
    if (state.custom && !customPath) {
      throw new Error("Enter the absolute path to a PEM CA bundle.");
    }
    if (!state.mozilla && !state.chrome && !customPath) {
      throw new Error("Select at least one trust source.");
    }
    if (customPath && customPath.charAt(0) !== "/") {
      throw new Error("The custom PEM path must be absolute on the TV.");
    }
    return [
      "mozilla=" + (state.mozilla ? "1" : "0"),
      "chrome=" + (state.chrome ? "1" : "0"),
      "custom_path_b64=" + (customPath ? encodeBase64(customPath) : "")
    ].join("\n") + "\n";
  }

  function parseStatus(text) {
    var result = {};
    var lines = String(text || "").split(/\r?\n/);
    var i;
    var separator;
    for (i = 0; i < lines.length; i += 1) {
      separator = lines[i].indexOf("=");
      if (separator > 0) {
        result[lines[i].slice(0, separator)] = lines[i].slice(separator + 1);
      }
    }
    return result;
  }

  function bootCheckMessage(state) {
    var messages = {
      "not-run": "Boot check has not run.",
      disabled: "Boot-time checks are disabled.",
      unchanged: "Last check found no changes in selected sources.",
      stale: "Last check used cached sources; no change was found.",
      "source-error": "Last source check failed; active trust was not changed.",
      invalid: "Source data was invalid; active trust was not changed."
    };
    var result = state.last_check || "not-run";
    if (state.staged === "1") {
      if (result === "staged-stale") return "A candidate from cached source data is staged; Apply to activate it.";
      if (result === "source-error" || result === "invalid") return "A previous valid candidate remains staged; the latest check failed. Apply to activate it.";
      return "A source update is staged; Apply to activate it.";
    }
    if (result === "staged") return "The staged source update has been applied.";
    if (result === "staged-stale") return "The cached-source candidate was applied; upstream refresh had failed.";
    return messages[result] || "Boot check status unavailable.";
  }

  return {
    bootCheckMessage: bootCheckMessage,
    buildSelection: buildSelection,
    decodeBase64: decodeBase64,
    encodeBase64: encodeBase64,
    parseStatus: parseStatus
  };
}));
