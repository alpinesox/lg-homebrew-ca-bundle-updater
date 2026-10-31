"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const elements = Object.create(null);
const calls = [];
const methods = [];
let foreignMount = "0";

function element(id) {
  if (!elements[id]) {
    elements[id] = {
      id,
      checked: false,
      disabled: false,
      hidden: false,
      value: "",
      textContent: "",
      className: "",
      handlers: Object.create(null),
      addEventListener(name, handler) { this.handlers[name] = handler; },
      focus() {},
      trigger(name) { this.handlers[name].call(this); }
    };
  }
  return elements[id];
}

const document = {
  addEventListener(name, handler) {
    if (name === "DOMContentLoaded") this.ready = handler;
  },
  getElementById: element
};

const context = {
  document,
  btoa: value => Buffer.from(value, "binary").toString("base64"),
  atob: value => Buffer.from(value, "base64").toString("binary"),
  confirm: () => true,
  webOS: {
    service: {
      request(uri, options) {
        calls.push(options.parameters.command);
        methods.push(options.method);
        if (options.method === "spawn") {
          assert.equal(options.parameters.subscribe, true);
          options.onSuccess({ event: "stdoutData", stdoutString: "Applied fixture bundle." });
          options.onSuccess({ event: "exit", exitCode: 0 });
        } else if (options.parameters.command.indexOf(" bootstrap") !== -1) {
          options.onSuccess({
            returnValue: true,
            stdoutString: "helper_path=/var/lib/webosbrew/ca-bundle-manager/releases/" + "a".repeat(64) + "/ca-manager.sh\n"
          });
        } else if (options.parameters.command.indexOf(" status") !== -1) {
          options.onSuccess({
            returnValue: true,
            stdoutString: "active=0\nmounted=0\nforeign_mount=" + foreignMount + "\nboot_checks=0\nmozilla=1\nchrome=0\ncustom_path_b64=\nactive_sha256=\ncertificate_count=0\nstaged=0\nlast_check=not-run\n"
          });
        } else {
          options.onSuccess({ returnValue: true, stdoutString: "ok" });
        }
      }
    }
  },
  console,
  encodeURIComponent,
  decodeURIComponent,
  escape,
  unescape
};
context.window = context;
vm.runInNewContext(fs.readFileSync("src/config.js", "utf8"), context);
vm.runInNewContext(fs.readFileSync("src/app.js", "utf8"), context);
document.ready();

assert.equal(element("source-mozilla").checked, true);
element("source-chrome").checked = true;
element("source-custom").checked = true;
element("custom-path").value = "/media/developer/TLS inspection; custom.pem";
element("apply-button").trigger("click");

const configureCommand = calls.find(command => command.indexOf(" configure ") !== -1);
assert.ok(configureCommand);
assert.ok(!configureCommand.includes("TLS inspection;"));
const payload = Buffer.from(configureCommand.split(" ").pop(), "base64").toString();
const customB64 = payload.match(/custom_path_b64=([^\n]+)/)[1];
assert.equal(Buffer.from(customB64, "base64").toString(), "/media/developer/TLS inspection; custom.pem");
assert.ok(calls.some(command => command.endsWith(" apply")));
assert.ok(methods.includes("spawn"));

element("boot-checks-button").trigger("click");
assert.ok(calls.some(command => command.endsWith(" boot-checks on")));
element("restore-button").trigger("click");
assert.ok(calls.some(command => command.endsWith(" restore")));
foreignMount = "1";
element("boot-checks-button").trigger("click");
assert.equal(element("active-indicator").textContent, "OTHER OVERLAY");
assert.equal(element("apply-button").disabled, true);
assert.equal(element("restore-button").disabled, true);
assert.match(element("action-result").textContent, /Another CA overlay is mounted/);

console.log("UI smoke tests passed");
