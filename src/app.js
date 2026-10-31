(function () {
  "use strict";

  var service = "luna://org.webosbrew.hbchannel.service";
  var bootstrapper = "sh /media/developer/apps/usr/palm/applications/com.alpinesox.cabundlemanager/scripts/ca-manager.sh";
  var helper = null;
  var config = window.CABundleConfig;
  var ids = ["apply-button", "boot-checks-button", "restore-button"];
  var busy = false;
  var rootStatus = null;

  function byId(id) {
    return document.getElementById(id);
  }

  function setMessage(message, isError) {
    var element = byId("action-result");
    element.textContent = message;
    element.className = isError ? "action-result error-text" : "action-result";
  }

  function setBusy(value) {
    var i;
    var inputIds = ["source-mozilla", "source-chrome", "source-custom", "custom-path"];
    busy = value;
    for (i = 0; i < ids.length; i += 1) {
      byId(ids[i]).disabled = value;
    }
    for (i = 0; i < inputIds.length; i += 1) {
      byId(inputIds[i]).disabled = value || (inputIds[i] === "custom-path" && !byId("source-custom").checked);
    }
  }

  function serviceCall(action, payload, callback, spawn) {
    var executable = action === "bootstrap" ? bootstrapper : helper;
    if (!executable) {
      callback(new Error("The root helper has not been bootstrapped yet."));
      return;
    }
    var command = executable + " " + action;
    var output = "";
    var completed = false;
    if (payload) {
      command += " " + (action === "configure" ? config.encodeBase64(payload) : payload);
    }
    if (typeof webOS === "undefined" || !webOS.service || typeof webOS.service.request !== "function") {
      callback(new Error("Homebrew Channel root service is unavailable."));
      return;
    }
    var parameters = { command: command };
    if (spawn) parameters.subscribe = true;
    try {
      webOS.service.request(service, {
        method: spawn ? "spawn" : "exec",
        parameters: parameters,
        onSuccess: function (response) {
          if (spawn) {
            if (!response || completed) return;
            var eventType = response.event || response.type;
            if (eventType === "stdoutData") output += response.stdoutString || "";
            if (eventType === "stderrData") output += response.stderrString || "";
            if (response.error || response.returnValue === false) {
              completed = true;
              callback(new Error(response.errorText || response.error || output || "Root helper failed."), output);
              return;
            }
            if (eventType === "exit" || eventType === "close") {
              completed = true;
              var code = response.exitCode !== undefined ? response.exitCode : response.closeCode;
              callback(code === 0 ? null : new Error(output || "Root helper failed."), output);
            }
            return;
          }
          if (!response || response.returnValue === false || response.error) {
            callback(new Error((response && (response.error || response.stderrString)) || "The root helper rejected the request."));
            return;
          }
          callback(null, response.stdoutString || "");
        },
        onFailure: function (response) {
          callback(new Error((response && (response.errorText || response.error)) || "Homebrew Channel root service is unavailable."));
        }
      });
    } catch (error) {
      callback(error);
    }
  }

  function showConnection(connected, text) {
    var chip = byId("connection-status");
    chip.className = connected ? "status-chip connected" : "status-chip error";
    byId("connection-label").textContent = text;
  }

  function applyStatus(text) {
    var state = config.parseStatus(text);
    rootStatus = state;
    byId("source-mozilla").checked = state.mozilla !== "0";
    byId("source-chrome").checked = state.chrome === "1";
    byId("custom-path").value = config.decodeBase64(state.custom_path_b64);
    byId("source-custom").checked = !!state.custom_path_b64;
    byId("custom-path").disabled = !byId("source-custom").checked;
    byId("custom-risk").hidden = !byId("source-custom").checked;
    byId("certificate-count").textContent = state.certificate_count || "—";
    byId("active-hash").textContent = state.active_sha256 || "Not applied";
    var foreignMount = state.foreign_mount === "1";
    byId("active-indicator").textContent = foreignMount ? "OTHER OVERLAY" : (state.mounted === "1" ? "APPLIED" : "STOCK");
    byId("active-indicator").className = foreignMount ? "active-indicator conflict" : (state.mounted === "1" ? "active-indicator applied" : "active-indicator");
    byId("staged-note").hidden = state.staged !== "1";
    byId("boot-checks-button").textContent = state.boot_checks === "1" ? "Disable boot-time checks" : "Enable boot-time checks";
    byId("apply-button").disabled = foreignMount;
    byId("restore-button").disabled = foreignMount;
    if (foreignMount) setMessage("Another CA overlay is mounted. Remove or restore it before applying this bundle.", true);
    updateBootCheckMessage(state);
    showConnection(true, "Root service ready");
  }

  function updateBootCheckMessage(state) {
    byId("boot-check-result").textContent = config.bootCheckMessage(state);
  }

  function refresh() {
    serviceCall("bootstrap", "", function (bootstrapError, bootstrapOutput) {
      if (bootstrapError) {
        rootStatus = null;
        showConnection(false, "Homebrew root service unavailable");
        setMessage(bootstrapError.message, true);
        return;
      }
      var bootstrapState = config.parseStatus(bootstrapOutput);
      var helperPath = bootstrapState.helper_path || "";
      if (!/^\/var\/lib\/webosbrew\/ca-bundle-manager\/releases\/[0-9a-f]{64}\/ca-manager\.sh$/.test(helperPath)) {
        rootStatus = null;
        showConnection(false, "Root helper bootstrap failed");
        setMessage("Homebrew did not return a valid protected-helper path.", true);
        return;
      }
      helper = helperPath;
      serviceCall("status", "", function (error, text) {
      if (error) {
        rootStatus = null;
        showConnection(false, "Homebrew root access unavailable");
        setMessage(error.message, true);
        return;
      }
      applyStatus(text);
      });
    });
  }

  function selectionPayload() {
    return config.buildSelection({
      mozilla: byId("source-mozilla").checked,
      chrome: byId("source-chrome").checked,
      custom: byId("source-custom").checked,
      customPath: byId("custom-path").value
    });
  }

  function applySelected() {
    var config;
    if (busy) return;
    if (!rootStatus) {
      setMessage("Wait for Homebrew root access to be checked.", true);
      return;
    }
    try {
      config = selectionPayload();
    } catch (error) {
      setMessage(error.message, true);
      return;
    }
    if (!window.confirm("Apply these selected roots system-wide? This changes trust for applications using the TV's system CA file.")) return;
    setBusy(true);
    setMessage("Validating sources and applying the bundle…", false);
    serviceCall("configure", config, function (error, text) {
      if (error) {
        setBusy(false);
        setMessage(error.message, true);
        return;
      }
      serviceCall("apply", "", function (applyError, result) {
        setBusy(false);
        if (applyError) {
          setMessage(applyError.message, true);
        } else {
          setMessage(result.trim() || "Bundle applied.", false);
        }
        refresh();
      }, true);
    });
  }

  function toggleBootChecks() {
    if (busy) return;
    if (!rootStatus) {
      setMessage("Wait for Homebrew root access to be checked.", true);
      return;
    }
    var enabled = rootStatus && rootStatus.boot_checks === "1";
    setBusy(true);
    serviceCall("boot-checks", enabled ? "off" : "on", function (error, text) {
      setBusy(false);
      setMessage(error ? error.message : (text.trim() || "Boot-time checks setting updated."), !!error);
      refresh();
    });
  }

  function restoreStock() {
    if (busy) return;
    if (!rootStatus) {
      setMessage("Wait for Homebrew root access to be checked.", true);
      return;
    }
    if (!window.confirm("Restore the TV's stock CA bundle and disable boot-time checks? The original firmware file will not be changed.")) return;
    setBusy(true);
    serviceCall("restore", "", function (error, text) {
      setBusy(false);
      setMessage(error ? error.message : (text.trim() || "Stock trust restored."), !!error);
      refresh();
    });
  }

  function init() {
    byId("source-custom").addEventListener("change", function () {
      byId("custom-path").disabled = !this.checked;
      byId("custom-risk").hidden = !this.checked;
      if (this.checked) byId("custom-path").focus();
    });
    byId("apply-button").addEventListener("click", applySelected);
    byId("boot-checks-button").addEventListener("click", toggleBootChecks);
    byId("restore-button").addEventListener("click", restoreStock);
    refresh();
  }

  document.addEventListener("DOMContentLoaded", init);
}());
