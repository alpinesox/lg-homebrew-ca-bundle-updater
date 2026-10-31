"use strict";

const assert = require("node:assert/strict");
const config = require("../src/config");

const path = "/media/developer/TLS inspection; custom.pem";
const payload = config.buildSelection({
  mozilla: true,
  chrome: false,
  custom: true,
  customPath: path
});

assert.match(payload, /^mozilla=1\nchrome=0\ncustom_path_b64=[A-Za-z0-9+/=]+\n$/);
assert.ok(!payload.includes(path));
assert.equal(config.decodeBase64(payload.match(/custom_path_b64=([^\n]+)/)[1]), path);
assert.throws(() => config.buildSelection({ mozilla: false, chrome: false, custom: false }), /Select at least one/);
assert.throws(() => config.buildSelection({ mozilla: true, chrome: false, custom: true, customPath: "relative.pem" }), /absolute/);
assert.deepEqual(config.parseStatus("active=1\ncustom_path_b64=YWJj==\nstaged=0\n"), {
  active: "1",
  custom_path_b64: "YWJj==",
  staged: "0"
});
assert.match(config.bootCheckMessage({ staged: "1", last_check: "source-error" }), /previous valid candidate remains staged/);
assert.match(config.bootCheckMessage({ staged: "1", last_check: "staged-stale" }), /cached source data is staged/);

console.log("UI config tests passed");
