(function () {
  "use strict";

  var service = "luna://org.webosbrew.hbchannel.service/";
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
    var actionUnavailable = value || !rootStatus || (rootStatus && rootStatus.foreign_mount === "1");
    for (i = 0; i < ids.length; i += 1) {
      byId(ids[i]).disabled = actionUnavailable;
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
    byId("certificate-count").textContent = state.mounted === "1" ? (state.certificate_count || "0") : "Not managed";
    byId("active-hash").textContent = state.mounted === "1" && state.active_sha256 ? state.active_sha256 : "Not managed";
    var foreignMount = state.foreign_mount === "1";
    byId("active-indicator").textContent = foreignMount ? "OTHER OVERLAY" : (state.mounted === "1" ? "APPLIED" : "STOCK");
    byId("active-indicator").className = foreignMount ? "active-indicator conflict" : (state.mounted === "1" ? "active-indicator applied" : "active-indicator");
    byId("staged-note").hidden = state.staged !== "1";
    byId("boot-checks-button").textContent = state.boot_checks === "1" ? "Disable boot-time checks" : "Enable boot-time checks";
    byId("apply-button").disabled = foreignMount;
    byId("restore-button").disabled = foreignMount;
    byId("boot-checks-button").disabled = busy || foreignMount;
    if (foreignMount) setMessage("Another CA overlay is mounted. Remove or restore it before applying this bundle.", true);
    updateBootCheckMessage(state);
    showConnection(true, "Root service ready");
  }

  function updateBootCheckMessage(state) {
    byId("boot-check-result").textContent = config.bootCheckMessage(state);
  }

  function handleRemoteArrow(event) {
    var active = document.activeElement;
    var panel = active && active.closest(".panel");
    var key = event.key;
    var direction;
    var searchRoot;
    var candidates;
    var sourceRect;
    var sourceX;
    var sourceY;
    var best = null;
    var bestScore = Infinity;
    var i;
    var candidate;
    var rect;
    var dx;
    var dy;
    var primary;
    var secondary;
    var score;
    if (!panel || active.matches("input[type=text], textarea, select, [contenteditable=true]")) return;
    if (key !== "ArrowUp" && key !== "ArrowDown" && key !== "ArrowLeft" && key !== "ArrowRight") return;
    direction = key.slice(5).toLowerCase();
    searchRoot = direction === "left" || direction === "right" ? byId("layout") : panel;
    sourceRect = active.getBoundingClientRect();
    sourceX = sourceRect.left + sourceRect.width / 2;
    sourceY = sourceRect.top + sourceRect.height / 2;
    candidates = searchRoot.querySelectorAll("button, input, [tabindex]");
    for (i = 0; i < candidates.length; i += 1) {
      candidate = candidates[i];
      if (candidate === active || candidate.matches(":disabled") || candidate.tabIndex < 0 || candidate.closest("[hidden], [inert]")) continue;
      rect = candidate.getBoundingClientRect();
      if (!rect.width || !rect.height || window.getComputedStyle(candidate).visibility === "hidden") continue;
      dx = rect.left + rect.width / 2 - sourceX;
      dy = rect.top + rect.height / 2 - sourceY;
      primary = direction === "up" ? -dy : (direction === "down" ? dy : (direction === "left" ? -dx : dx));
      if (primary <= 0) continue;
      secondary = direction === "up" || direction === "down" ? Math.abs(dx) : Math.abs(dy);
      score = primary + secondary * 1.5;
      if (score < bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    if (best) {
      event.preventDefault();
      best.focus();
    }
  }

  function refresh() {
    serviceCall("bootstrap", "", function (bootstrapError, bootstrapOutput) {
      if (bootstrapError) {
        rootStatus = null;
        showConnection(false, "Homebrew root service unavailable");
        setMessage(bootstrapError.message, true);
        setBusy(false);
        return;
      }
      var bootstrapState = config.parseStatus(bootstrapOutput);
      var helperPath = bootstrapState.helper_path || "";
      if (!/^\/var\/lib\/webosbrew\/ca-bundle-manager\/releases\/[0-9a-f]{64}\/ca-manager\.sh$/.test(helperPath)) {
        rootStatus = null;
        showConnection(false, "Root helper bootstrap failed");
        setMessage("Homebrew did not return a valid protected-helper path.", true);
        setBusy(false);
        return;
      }
      helper = helperPath;
      serviceCall("status", "", function (error, text) {
      if (error) {
        rootStatus = null;
        showConnection(false, "Homebrew root access unavailable");
        setMessage(error.message, true);
        setBusy(false);
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
    if (busy) return;
    if (!rootStatus) {
      setMessage("Wait for Homebrew root access to be checked.", true);
      return;
    }
    try {
      selectionPayload();
    } catch (error) {
      setMessage(error.message, true);
      return;
    }
    byId("apply-confirmation").hidden = false;
    byId("apply-confirm-button").focus();
  }

  function confirmApply() {
    var selection;
    if (busy) return;
    if (!rootStatus) {
      setMessage("Wait for Homebrew root access to be checked.", true);
      return;
    }
    try {
      selection = selectionPayload();
    } catch (error) {
      setMessage(error.message, true);
      return;
    }
    byId("apply-confirmation").hidden = true;
    setBusy(true);
    setMessage("Applying selected roots…", false);
    serviceCall("configure", selection, function (error) {
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
    byId("restore-confirmation").hidden = false;
    byId("restore-confirm-button").focus();
  }

  function confirmRestore() {
    if (busy || !rootStatus) return;
    byId("restore-confirmation").hidden = true;
    setBusy(true);
    setMessage("Restoring stock trust…", false);
    serviceCall("restore", "", function (error, text) {
      setBusy(false);
      setMessage(error ? error.message : (text.trim() || "Stock trust restored."), !!error);
      refresh();
    });
  }

  function init() {
    document.addEventListener("keydown", handleRemoteArrow);
    byId("source-custom").addEventListener("change", function () {
      byId("custom-path").disabled = !this.checked;
      byId("custom-risk").hidden = !this.checked;
      if (this.checked) byId("custom-path").focus();
    });
    byId("apply-button").addEventListener("click", applySelected);
    byId("apply-confirm-button").addEventListener("click", confirmApply);
    byId("apply-cancel-button").addEventListener("click", function () { byId("apply-confirmation").hidden = true; });
    byId("boot-checks-button").addEventListener("click", toggleBootChecks);
    byId("restore-button").addEventListener("click", restoreStock);
    byId("restore-confirm-button").addEventListener("click", confirmRestore);
    byId("restore-cancel-button").addEventListener("click", function () { byId("restore-confirmation").hidden = true; });
    setBusy(false);
    refresh();
  }

  document.addEventListener("DOMContentLoaded", init);
}());
