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
  fs.copyFileSync(path.join(ROOT, "package.properties"), path.join(DIST, "package.properties"));
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
  const buildTime = new Date();
  function touchTree(directory) {
    for (const name of fs.readdirSync(directory)) {
      const pathname = path.join(directory, name);
      if (fs.statSync(pathname).isDirectory()) touchTree(pathname);
      fs.utimesSync(pathname, buildTime, buildTime);
    }
    fs.utimesSync(directory, buildTime, buildTime);
  }
  touchTree(DIST);
}

function ares(args) {
  const command = process.platform === "win32"
    ? process.execPath
    : path.join(ROOT, "node_modules", ".bin", "ares-package");
  const commandArgs = process.platform === "win32"
    ? [path.join(ROOT, "node_modules", "@webos-tools", "cli", "bin", "ares-package.js")].concat(args)
    : args;
  execFileSync(command, commandArgs, {
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

function normalizeLinuxIpkTimestamps() {
  if (process.platform === "win32") return;
  const tempDir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ca-bundle-ipk-"));
  const rebuilt = path.join(tempDir, "rebuilt.ipk");
  try {
    execFileSync("ar", ["x", IPK], { cwd: tempDir });
    execFileSync("python3", ["-c", [
      "import pathlib, sys, tarfile, time",
      "root, output = pathlib.Path(sys.argv[1]), sys.argv[2]",
      "now = int(time.time())",
      "with tarfile.open(output, 'w:gz', format=tarfile.USTAR_FORMAT) as archive:",
      "  for path in sorted(root.rglob('*')):",
      "      info = archive.gettarinfo(str(path), arcname=path.relative_to(root).as_posix())",
      "      info.mtime = now",
      "      if info.isfile():",
      "        with path.open('rb') as stream: archive.addfile(info, stream)",
      "      else: archive.addfile(info)",
    ].join("\n"), DIST, path.join(tempDir, "data.tar.gz")]);
    execFileSync("ar", ["rcs", rebuilt, "debian-binary", "control.tar.gz", "data.tar.gz"], { cwd: tempDir });
    fs.renameSync(rebuilt, IPK);
    verifyLinuxIpk();
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function verifyLinuxIpk() {
  if (process.platform === "win32") return;
  const tempDir = fs.mkdtempSync(path.join(require("node:os").tmpdir(), "ca-bundle-verify-"));
  try {
    execFileSync("ar", ["x", IPK], { cwd: tempDir });
    const data = execFileSync("tar", ["-tvzf", "data.tar.gz"], { cwd: tempDir, encoding: "utf8" });
    if (/Dec 31\s+1969/.test(data)) throw new Error("IPK contains epoch-dated files");
    for (const filename of ["ca-manager.sh", "boot-hook.sh"]) {
      if (!new RegExp(`^-rwx[^\\n]*\\/${filename}$`, "m").test(data)) {
        throw new Error(`IPK helper is not executable: ${filename}`);
      }
    }
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function packageApp() {
  stage();
  ares(["-c", DIST]);
  const buildTime = new Date();
  for (const entry of fs.readdirSync(DIST, { recursive: true, withFileTypes: true })) {
    fs.utimesSync(path.join(entry.parentPath, entry.name), buildTime, buildTime);
  }
  ares([DIST, "--outdir", BUILD, "--app-exclude", "icon128.png.b64"]);
  const packaged = fs.readdirSync(BUILD).filter(name => name.endsWith(".ipk"));
  if (packaged.length !== 1) throw new Error(`Expected one IPK, found ${packaged.length}`);
  const source = path.join(BUILD, packaged[0]);
  if (source !== IPK) fs.renameSync(source, IPK);
  normalizeLinuxIpkTimestamps();
  verifyLinuxIpk();
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
