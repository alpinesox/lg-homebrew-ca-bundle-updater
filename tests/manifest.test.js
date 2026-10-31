"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { createManifest } = require("../tools/manifest");

const app = {
  id: "com.alpinesox.cabundlemanager",
  title: "CA Bundle Manager",
  version: "0.1.0",
  type: "web",
  appDescription: "Select and apply CA roots on a rooted webOS TV."
};
const ipk = Buffer.from("test IPK bytes");
const manifest = createManifest(app, ipk);

assert.equal(manifest.id, app.id);
assert.equal(manifest.version, app.version);
assert.equal(manifest.rootRequired, true);
assert.equal(manifest.ipkHash.sha256, crypto.createHash("sha256").update(ipk).digest("hex"));
assert.equal(manifest.ipkSize, ipk.length);
assert.match(manifest.ipkUrl, /releases\/download\/v0\.1\.0\/com\.alpinesox\.cabundlemanager\.ipk$/);
assert.match(manifest.iconUri, /^https:\/\//);
assert.throws(() => createManifest(app, Buffer.alloc(0)), /empty/);
assert.throws(() => createManifest({ ...app, id: "bad id" }, ipk), /id/);

console.log("manifest tests passed");
