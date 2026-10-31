"use strict";

const crypto = require("node:crypto");

const REPOSITORY = "alpinesox/lg-homebrew-ca-bundle-updater";

function createManifest(app, ipk) {
  if (!app || typeof app.id !== "string" || !/^[a-z0-9]+(?:\.[a-z0-9-]+)+$/.test(app.id)) {
    throw new Error("Invalid app id");
  }
  if (!Buffer.isBuffer(ipk) || ipk.length === 0) {
    throw new Error("IPK artifact is missing or empty");
  }

  const sha256 = crypto.createHash("sha256").update(ipk).digest("hex");
  return {
    id: app.id,
    title: app.title,
    version: app.version,
    type: app.type,
    appDescription: app.appDescription,
    iconUri: `https://raw.githubusercontent.com/${REPOSITORY}/main/assets/icon.svg`,
    ipkUrl: `https://github.com/${REPOSITORY}/releases/download/v${app.version}/${app.id}.ipk`,
    ipkHash: { sha256 },
    ipkSize: ipk.length,
    installedSize: ipk.length,
    rootRequired: true,
    sourceUrl: `https://github.com/${REPOSITORY}`
  };
}

module.exports = { createManifest };
