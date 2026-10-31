"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { createManifest } = require("./manifest");
const validateReleaseTag = require("./release-version");

const ROOT = path.resolve(__dirname, "..");
const DIST = path.join(ROOT, "dist");
const BUILD = path.join(ROOT, "build");
const APPINFO = JSON.parse(fs.readFileSync(path.join(ROOT, "appinfo.json"), "utf8"));
const PACKAGE = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8"));
const IPK = path.join(BUILD, `${APPINFO.id}.ipk`);

if (APPINFO.version !== PACKAGE.version) {
  throw new Error(`appinfo.json version ${APPINFO.version} does not match package.json ${PACKAGE.version}`);
}
validateReleaseTag(APPINFO);

function remove(pathname) {
  fs.rmSync(pathname, { recursive: true, force: true });
}

function stage() {
  remove(DIST);
  remove(BUILD);
  fs.mkdirSync(path.join(DIST, "assets"), { recursive: true });
  fs.mkdirSync(BUILD, { recursive: true });
  fs.copyFileSync(path.join(ROOT, "appinfo.json"), path.join(DIST, "appinfo.json"));
  fs.copyFileSync(path.join(ROOT, "index.html"), path.join(DIST, "index.html"));
  fs.cpSync(path.join(ROOT, "src"), path.join(DIST, "src"), { recursive: true });
  fs.cpSync(path.join(ROOT, "scripts"), path.join(DIST, "scripts"), { recursive: true });
  fs.copyFileSync(path.join(ROOT, "assets", "icon.svg"), path.join(DIST, "assets", "icon.svg"));

  const iconData = fs.readFileSync(path.join(ROOT, "assets", "icon128.png.b64"), "utf8").trim();
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(iconData)) throw new Error("Icon source is not valid base64");
  const icon = Buffer.from(iconData, "base64");
  if (!icon.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error("Icon source is not a PNG");
  }
  if (icon.readUInt32BE(16) !== 128 || icon.readUInt32BE(20) !== 128) {
    throw new Error("Icon must be 128 by 128 pixels");
  }
  fs.writeFileSync(path.join(DIST, "assets", "icon.png"), icon);
  fs.chmodSync(path.join(DIST, "scripts", "ca-manager.sh"), 0o755);
  fs.chmodSync(path.join(DIST, "scripts", "boot-hook.sh"), 0o755);
}

function ares(args) {
  const command = path.join(ROOT, "node_modules", "@webosose", "ares-cli", "bin", "ares-package.js");
  execFileSync(process.execPath, [command].concat(args), {
    cwd: ROOT,
    stdio: "inherit"
  });
}

function writeManifest() {
  if (!fs.existsSync(IPK)) throw new Error(`Missing package artifact: ${IPK}`);
  const manifest = createManifest(APPINFO, fs.readFileSync(IPK));
  const json = `${JSON.stringify(manifest, null, 2)}\n`;
  fs.writeFileSync(path.join(ROOT, "manifest.json"), json);
  fs.writeFileSync(path.join(BUILD, "manifest.json"), json);
}

function packageApp() {
  stage();
  ares(["-c", DIST]);
  ares([DIST, "--outdir", BUILD]);
  const packaged = fs.readdirSync(BUILD).filter(name => name.endsWith(".ipk"));
  if (packaged.length !== 1) throw new Error(`Expected one IPK, found ${packaged.length}`);
  const source = path.join(BUILD, packaged[0]);
  if (source !== IPK) fs.renameSync(source, IPK);
  ares(["-i", IPK]);
  writeManifest();
  console.log(`Built ${path.relative(ROOT, IPK)} and manifest.json`);
}

if (process.argv[2] === "manifest") {
  writeManifest();
} else if (process.argv.length === 2) {
  packageApp();
} else {
  console.error("Usage: node tools/build.js [manifest]");
  process.exitCode = 2;
}
