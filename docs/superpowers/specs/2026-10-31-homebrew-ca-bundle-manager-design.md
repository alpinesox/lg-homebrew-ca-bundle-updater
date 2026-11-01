# Homebrew CA Bundle Manager Design

## Goal

Build an open-source Homebrew Channel app for LG webOS TVs that lets users choose CA sources, explicitly apply a merged system bundle, and optionally check for source updates at boot. The UI checks whether elevated Homebrew execution is available and warns/disables actions when it is not.

## Scope

- Mozilla's current public root set, downloaded as PEM from curl.se.
- Chrome's official Chrome Root Store, limited to roots listed under `Trusted Roots`; exclude `Constrained Roots` because a plain OpenSSL CA bundle cannot apply Chrome's external per-root constraints.
- Optional custom PEM bundle from a user-specified path on the TV.
- No Apple provider checkbox. Apple's published PKI list is Apple's own PKI, not a complete Apple-platform trust store; users may import a PEM bundle through the custom path.
- A TV UI with provider checkboxes, custom-path input, an **Apply** action, a separate **Enable boot-time checks** toggle, and a **Restore stock trust** action.
- A production IPK, public GitHub repository, release manifest, and Homebrew catalog submission.

## Trust semantics

The app does not silently select additional providers. The Mozilla checkbox is initially checked in the UI; Chrome and custom roots are opt-in. The active bundle is exactly the deduplicated union of the selected source certificates.

Mozilla and Chrome root-program constraints and trust-purpose metadata are not all representable in a plain PEM CA file. curl.se explicitly documents that its Mozilla PEM export omits Firefox's external constraints. The UI and README must explain that the resulting system trust anchors may be broader than browser-specific policy. Chrome constrained roots are excluded, but the remaining Chrome roots still do not reproduce Chrome's complete verifier policy.

Custom input is a readable PEM file containing CA certificates. The app copies validated certificate bytes into app-managed storage; it does not retain an unchecked arbitrary path as the live bundle.

## Apply and boot behavior

- **Apply** builds and validates a candidate, then bind-mounts it over `/etc/ssl/certs/ca-certificates.crt` immediately and records it as the approved bundle for the next boot. It does not require a reboot to change the path used by new TLS connections.
- Already-running applications may cache trust state; the UI must advise relaunching those apps, and rebooting if they still use the old trust set.
- A root-owned Homebrew startup wrapper re-applies the last approved bundle on boot. It validates its own installed hash/ownership before replacement, and self-removes if the app is uninstalled. If the bundle is missing, invalid, or cannot be mounted, the hook leaves the stock file visible and logs the failure.
- **Enable boot-time checks** only enables checks for selected upstream sources at boot. A newer candidate is staged and reported; it is not applied until the user presses **Apply**.
- **Restore stock trust** disables boot-time checks and boot application before unmounting the overlay, then removes the startup hook. The firmware CA file is never overwritten.
- A read-only copy of the stock CA bundle is retained in root-owned protected state for rollback and source-fetch TLS bootstrap.

## Privilege boundary

The UI uses the documented Homebrew Channel root execution Luna service to bootstrap a root-owned helper under `/var/lib/webosbrew/ca-bundle-manager`, then invokes fixed helper actions. It never sends an arbitrary shell command assembled from free-form user input. User configuration is encoded as base64 for transport, then strictly validated by the root helper. The root helper accepts only enumerated provider flags and a custom PEM path; it never evaluates or sources user data. Trust data, the original-bundle backup, and active-state files are stored in root-owned managed storage, not in the world-writable developer app directory.

The UI reports failure when Homebrew Channel/root access is unavailable and does not claim success until the helper confirms the mount or state change.

Homebrew Channel's documented root execution endpoint is unrestricted and available to other Homebrew apps on rooted TVs. This app keeps its own commands fixed and validates data, but cannot provide isolation from another malicious Homebrew app; the README must disclose that platform trust boundary.

## Source update verification

- Mozilla PEM and its published SHA-256 are fetched over HTTPS; the PEM must match the published digest and parse before it is staged.
- The Mozilla digest is published beside the PEM on the same HTTPS origin; it detects transfer errors but is not an independent publisher signature.
- Provider-fetch TLS uses the original firmware trust bundle, plus selected custom CA material if needed. This bootstrap trust is not implicitly merged into the active CA bundle.
- Chrome source files are fetched from official Chromium Gitiles `main`; the root-store version and every per-certificate SHA-256 identity in the `Trusted Roots` section are checked against `root_store.certs`. A mixed or incomplete snapshot is rejected.
- Gitiles' history endpoint denied unauthenticated requests during research, while direct source-file requests succeeded. The provider therefore records the root-store version and cross-validates the fetched data rather than claiming an immutable commit pin.
- Custom PEM sources are local-only and are never fetched by the boot checker.
- Boot checks stage provider changes without modifying the active bundle.
- On network, checksum, parse, or mount failure, retain the last approved bundle and leave the original system file intact.

## Validation

- Shell tests cover certificate parsing, SHA-256 deduplication, invalid/empty input rejection, exclusion of Chrome constrained roots, and safe state parsing.
- UI tests or a small browser harness cover checkbox state, boot-check toggle, Apply, Restore, root-service errors, and status display.
- CI packages the IPK and validates the manifest/hash.
- Device testing on the rooted C2 validates live apply, restore, boot reapply, boot-time update staging, offline fallback, and root-service-unavailable handling before catalog submission.

## Release

The project repository is public at `alpinesox/lg-homebrew-ca-bundle-updater`. Releases provide the IPK and Homebrew manifest; the manifest points to the matching versioned IPK asset, while the catalog entry points to the latest manifest. Catalog submission is a pull request to `webosbrew/apps-repo`; the listing must describe root requirements, trust-scope limitations, and the fact that AI assistance was used and the human maintainer reviewed and tested the result.

## References

- [curl.se Mozilla CA extract and limitations](https://curl.se/docs/caextract.html)
- [Mozilla Root Store Policy](https://www.mozilla.org/en-US/about/governance/policies/security-group/certs/policy/)
- [Chromium Chrome Root Store artifacts](https://chromium.googlesource.com/chromium/src/+/main/net/data/ssl/chrome_root_store/)
- [Apple PKI certificate list](https://www.apple.com/certificateauthority/)
- [Homebrew startup-script guide](https://www.webosbrew.org/develop/guides/startup-script)
- [Homebrew system-mod guide](https://www.webosbrew.org/develop/guides/system-mods)
- [Homebrew app catalog submission rules](https://github.com/webosbrew/apps-repo#submit-your-application)
