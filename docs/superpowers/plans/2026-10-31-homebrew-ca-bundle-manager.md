# Homebrew CA Bundle Manager Implementation Plan

> **For agentic workers:** Execute this plan inline, task by task. Each task must leave a runnable verification result.

**Goal:** Build and publish a webOS Homebrew app for selecting Mozilla, Chrome-unconstrained, and custom CA sources, applying the selected bundle, and optionally staging source updates at boot.

**Architecture:** A TV-friendly webOS app UI talks to the rooted Homebrew Channel Luna execution service using fixed helper actions. A root shell helper validates source data, builds a deterministic PEM bundle, applies it by bind mount, and is called by a Homebrew startup hook; boot checks stage updates but never auto-apply them.

**Tech Stack:** webOS web app (HTML/CSS/JavaScript), POSIX shell, OpenSSL/curl/awk/base64 already present on supported TVs, `ares-package`, Node-based local tests and build scripts, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-31-homebrew-ca-bundle-manager-design.md`

## Global Constraints

- Never write over `/etc/ssl/certs/ca-certificates.crt`; use bind mounts only.
- Only apply roots from user-selected Mozilla, Chrome unconstrained, and custom PEM sources.
- Chrome constrained roots are excluded from the PEM provider.
- Boot-time checks stage updates; only the explicit Apply action changes active trust.
- Restore stock trust must work offline and must not depend on a successful network request.
- All user-supplied values are data, never shell code.
- Do not claim universal webOS compatibility from tests on one TV.

### Task 1: Provider bundle builder and tests

**Files:**
- Create: `scripts/lib/bundle.sh`
- Create: `scripts/ca-manager.sh`
- Create: `tests/bundle-tests.sh`
- Create: `package.json`

**Interfaces:**
- `bundle.sh` exports `ca_bundle_validate`, `ca_bundle_add_pem`, and `ca_bundle_add_chrome`; these functions do not mount or modify the system trust file.
- `ca-manager.sh` exposes only the fixed actions `status`, `configure`, `apply`, `restore`, `boot-checks on|off`, `check`, and `startup`.

- [x] **Step 1: Write failing shell tests** for valid Mozilla/custom PEM union, duplicate cert removal by DER SHA-256, invalid PEM rejection, and Chrome constrained-root exclusion using generated test CA certificates.
- [x] **Step 2: Run `npm test`** and confirm the tests fail because the helper does not exist.
- [x] **Step 3: Implement strict configuration parsing and certificate splitting/validation** in `scripts/lib/bundle.sh`; no `eval`, `source`, or interpolation of user-supplied paths into shell code.
- [x] **Step 4: Implement Mozilla acquisition** from `https://curl.se/ca/cacert.pem` plus `.sha256`, requiring digest equality and successful OpenSSL parse before staging.
- [x] **Step 5: Implement Chrome acquisition** from official Gitiles `main` `root_store.certs` and `root_store.md`; parse only `Trusted Roots`, include only matching certificate DER hashes, and reject incomplete/mixed snapshots by comparing extracted and published root counts.
- [x] **Step 6: Implement custom PEM ingestion** from a readable absolute path; copy validated CA certificate bytes into managed state and deduplicate by SHA-256.
- [x] **Step 7: Run `npm test` and shell syntax checks**; require all tests to pass and malformed inputs to leave staged/active state unchanged.

### Task 2: Safe apply, restore, and boot-time check behavior

**Files:**
- Create: `scripts/ca-manager.sh`
- Create: `scripts/boot-hook.sh`
- Modify: `scripts/lib/bundle.sh`
- Create: `tests/lifecycle-tests.sh`

**Interfaces:**
- `status` returns machine-readable state for active hash, chosen sources, boot-check setting, and staged-update state.
- `configure <base64-payload>` accepts only the fixed provider booleans and a base64 custom path; the helper parses decoded data as values and never evaluates it.
- `apply` validates, backs up stock trust once, atomically installs the approved bundle in writable storage, mounts it over the system bundle, and installs the startup hook.
- `restore` unmounts the target, disables both boot actions, removes the startup hook, and leaves all backups intact.
- `boot-checks on|off` toggles checks independently of whether a bundle is applied.

- [x] **Step 1: Write failing lifecycle tests** for idempotent Apply, offline Restore, boot mount failure fallback, and update staging without active-bundle changes.
- [x] **Step 2: Run lifecycle tests** and confirm the expected failures.
- [x] **Step 3: Implement stock backup and bind-mount apply** with atomic files, hash verification, mount-state checks, and fallback to stock on failure.
- [x] **Step 4: Implement `restore`** so it needs no network, removes the startup link, clears active/boot-check flags, and verifies the original CA path is exposed.
- [x] **Step 5: Implement boot hook** that re-applies only the last approved bundle and runs source checks only when enabled; checks stage candidates and never auto-apply.
- [x] **Step 6: Run lifecycle tests and verify** malformed settings or failed downloads do not alter the current mounted bundle.

### Task 3: webOS TV app UI and privileged-service integration

**Files:**
- Create: `appinfo.json`
- Create: `index.html`
- Create: `src/app.js`
- Create: `src/app.css`
- Create: `assets/icon.png`
- Modify: `package.json`

**Interfaces:**
- UI calls `luna://org.webosbrew.hbchannel.service/exec` with a fixed helper path/action; configuration is base64 data and is revalidated by the helper.
- UI displays root/HBC availability, selected provider counts, active/staged state, last update result, and helper errors.

- [x] **Step 1: Create the app metadata and basic screen** with accessible focus order, remote-control navigation, Mozilla/Chrome/custom checkboxes, custom path field, Apply, boot-check toggle, Restore, and result status; provider checkboxes are usable without root access, while privileged actions wait for the runtime root-service check.
- [x] **Step 2: Add UI tests or a browser harness** for selection, validation, error display, and all three actions.
- [x] **Step 3: Implement the Homebrew Luna bridge** using fixed action strings and base64-encoded config data; do not use arbitrary UI-provided shell command fragments.
- [x] **Step 4: Wire Apply, boot checks, Restore, and status refresh** to helper responses and only show success after confirmed results.
- [x] **Step 5: Add clear warnings** that a PEM bundle cannot reproduce browser-specific external CA constraints and that applications may cache trust until relaunched.
- [x] **Step 6: Run frontend tests and inspect** that buttons and errors remain readable/focusable at TV resolution.

### Task 4: IPK packaging, CI, and catalog release metadata

**Files:**
- Create: `tools/build.js`
- Create: `manifest.json`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Modify: `package.json`
- Modify: `README.md`
- Create: `LICENSE`

**Interfaces:**
- `npm test` runs local tests and shell checks.
- `npm run package` stages only runtime files and creates the IPK with `ares-package`.
- `npm run manifest` emits the Homebrew manifest with version, IPK URL/hash/size, and project/source URL.

- [x] **Step 1: Write build/manifest tests** that reject missing IPK, invalid app ID, and incorrect SHA-256 while accepting a correctly packaged artifact.
- [x] **Step 2: Implement packaging scripts** with a versioned app ID, reproducible output paths, and generated manifest metadata.
- [x] **Step 3: Configure CI** to run tests, package the IPK, and inspect the IPK contents without publishing on ordinary branches.
- [x] **Step 4: Configure tagged releases** to publish the IPK and manifest only after CI succeeds.
- [x] **Step 5: Write user documentation** for root/HBC prerequisites, source choices, constraints caveat, apply/restore, boot checks, rollback, and known limitations.
- [x] **Step 6: Run the complete test/build suite** and verify package metadata, manifest digest, and packaged file list.

### Task 5: Device validation and Homebrew catalog submission

**Files:**
- Modify: `README.md` if device findings change supported claims.
- Create: `packages/com.alpinesox.cabundlemanager.yml` in a fork of `webosbrew/apps-repo`.

- [ ] **Step 1: Install the IPK on the rooted LG C2** and verify root detection, status query, and disabled-by-default behavior.
- [ ] **Step 2: Test Mozilla-only Apply and Restore**; confirm the original system bundle hash is unchanged and TLS checks pass after mount/unmount.
- [ ] **Step 3: Test Chrome/custom selections and boot checks**; confirm constrained roots are excluded and new source data is staged but not applied.
- [ ] **Step 4: Test reboot and offline startup**; confirm approved bundle re-mounts and stock trust remains available if a source check fails.
- [ ] **Step 5: Publish a versioned GitHub Release** after the tests pass and attach the IPK plus generated manifest.
- [ ] **Step 6: Submit the catalog entry PR** to `webosbrew/apps-repo`, including required disclosure that AI assistance was used and human review/device testing was performed.
