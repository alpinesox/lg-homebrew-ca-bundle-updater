"use strict";

const assert = require("node:assert/strict");
const validateReleaseTag = require("../tools/release-version");

const app = { version: "0.1.1" };
assert.doesNotThrow(() => validateReleaseTag(app, { GITHUB_REF_TYPE: "branch", GITHUB_REF_NAME: "feature/ca-bundle-manager" }));
assert.doesNotThrow(() => validateReleaseTag(app, { GITHUB_REF_TYPE: "tag", GITHUB_REF_NAME: "v0.1.1" }));
assert.throws(() => validateReleaseTag(app, { GITHUB_REF_TYPE: "tag", GITHUB_REF_NAME: "v0.1.0" }), /does not match/);

console.log("release version tests passed");
