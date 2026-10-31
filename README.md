# CA Bundle Manager for webOS

A rooted webOS Homebrew app for selecting CA sources, explicitly applying their certificates as system trust anchors, and optionally checking for upstream source updates at boot.

## Requirements

- A rooted LG webOS TV.
- Homebrew Channel installed and its root execution service available.
- A writable `/media/developer` partition and the Homebrew startup-script mechanism.
- `curl`, `openssl`, `sha256sum`, `base64`, `awk`, `mount`, `umount`, `findmnt`, `stat`, and `nohup` on the TV.

This app does not update LG firmware, the kernel, OpenSSL, or other system binaries.

## Trust sources

- **Mozilla** is selected by default and uses curl.se's PEM export of Mozilla's root store. Its adjacent SHA-256 file is fetched over HTTPS from the same host. The checksum detects transfer errors; it is not an independent signature.
- **Chrome** is optional and uses the official Chromium Chrome Root Store data from Gitiles `main`. The root-store version and every listed certificate SHA-256 are checked. Only entries in `Trusted Roots` are included; `Constrained Roots` are excluded. This is still a plain PEM CA file, not Chrome's full verifier policy.
- **Custom PEM** is optional. Enter an absolute path to a PEM file on the TV. The file must contain CA certificates; the app validates and copies the certificates into managed storage.

Mozilla and Chrome apply additional purpose, scope, and policy rules that a plain OpenSSL CA file cannot fully represent. curl.se specifically warns that Mozilla's PEM export omits Firefox's external CA constraints. The selected certificates may therefore be trusted more broadly by system consumers than by Firefox or Chrome. Apple does not publish a complete Apple-device trust bundle; use the custom PEM option if you have a bundle you choose to trust.

## Applying and updating

- **Apply selected roots** builds a deduplicated PEM bundle, validates it, and bind-mounts it over `/etc/ssl/certs/ca-certificates.crt`. The firmware file itself is never overwritten. Apply takes effect immediately for new TLS connections and installs the startup hook to reapply the approved bundle on boot.
- **Enable boot-time checks** checks selected public sources at startup and stages changed data. It does not silently apply updates; review the staged state and press Apply.
- **Restore stock trust** unmounts the managed bundle, disables boot-time behavior, and exposes the original system bundle. It works offline.

Apply and Restore do not inherently require a reboot. Some running apps may cache the trust store; relaunch them, or reboot if they continue using old trust.

Source downloads are authenticated using the original stock CA bundle, plus the selected custom CA when configured. Mozilla's checksum is fetched from the same HTTPS host as its bundle; it detects transfer errors but is not an independent signature. Chrome's certificate hashes are checked against its `root_store.md` data. If a source, checksum, certificate parse, or mount check fails, the last approved bundle is retained and no new trust is activated.

Only applications that use `/etc/ssl/certs/ca-certificates.crt` are affected. Some apps ship their own CA store or cache trust independently.

## Recovery and removal

The app keeps an untouched copy of the original system bundle in app-managed storage. If Apply fails, the helper rolls back to the prior active bundle or stock trust. Use **Restore stock trust** before uninstalling. If the app is removed without restoring first, the active bind mount lasts only until reboot; the small boot hook detects the missing app and removes itself, leaving the original system bundle visible.

The UI invokes Homebrew Channel's root execution service. Install this app only if you trust its source and understand that an applied CA can validate TLS chains system-wide. A custom interception CA gives its private-key holder the ability to intercept connections trusting that CA. The boot wrapper removes itself if the app is uninstalled; the active bind mount lasts until reboot, when the untouched firmware bundle becomes visible again.

## Build and test

Requires Node.js 20 or newer, npm, OpenSSL, a POSIX shell, and the webOS Ares CLI.

```sh
npm ci
npm test
npm run check:shell
npm run package
```

`npm run package` creates `build/com.alpinesox.cabundlemanager.ipk` and a release `manifest.json`. `npm run test:providers` performs live HTTPS checks against curl.se and Chromium Gitiles; it is separate from the offline test suite.

The current test suite runs on the build host. Before a Homebrew catalog release, test Apply, Restore, boot reapply, boot-time staging, offline behavior, and an unavailable root service on rooted TVs. Testing on one model does not establish compatibility with all webOS versions or rooting methods.

## Homebrew submission

The public IPK and manifest are published as GitHub Release assets. Catalog submission is made through a pull request to [`webosbrew/apps-repo`](https://github.com/webosbrew/apps-repo). Homebrew requires AI-assistance disclosure and meaningful human review/testing; the maintainer is responsible for the code and release.
