from pathlib import Path
from tempfile import gettempdir

from playwright.sync_api import sync_playwright


def main():
    app = (Path(__file__).resolve().parents[1] / "index.html").as_uri()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        errors = []
        page.add_init_script("""
          window.__manager = {
            active: '0', mounted: '0', foreign_mount: '0', boot_checks: '0',
            mozilla: '1', chrome: '0', custom_path_b64: '', active_sha256: '',
            certificate_count: '0', staged: '0', last_check: 'not-run', selection: ''
          };
          function statusText() {
            return Object.keys(window.__manager).filter(function (key) {
              return key !== 'selection';
            }).map(function (key) {
              return key + '=' + window.__manager[key];
            }).join('\\n') + '\\n';
          }
          window.__mockWebOS = { service: { request: function (uri, options) {
            if (uri !== 'luna://org.webosbrew.hbchannel.service/' || options.method !== (options.parameters.subscribe ? 'spawn' : 'exec')) {
              throw new Error('Unexpected Homebrew service URI: ' + uri);
            }
            var command = options.parameters.command;
            var action = command.split(' ').pop();
            if (command.indexOf(' bootstrap') !== -1) {
              options.onSuccess({ returnValue: true, stdoutString: 'helper_path=/var/lib/webosbrew/ca-bundle-manager/releases/' + 'a'.repeat(64) + '/ca-manager.sh\\n' });
              return;
            }
            if (action === 'status') {
              options.onSuccess({ returnValue: true, stdoutString: statusText() });
              return;
            }
            if (command.indexOf(' configure ') !== -1) {
              var payload = atob(command.split(' ').pop());
              window.__manager.selection = payload;
              payload.split('\\n').forEach(function (line) {
                var index = line.indexOf('=');
                if (index > 0) window.__manager[line.slice(0, index)] = line.slice(index + 1);
              });
              options.onSuccess({ returnValue: true, stdoutString: 'Selection saved.' });
              return;
            }
            if (action === 'apply') {
              window.__manager.active = '1';
              window.__manager.mounted = '1';
              window.__manager.active_sha256 = 'b'.repeat(64);
              window.__manager.certificate_count = '120';
              window.__manager.staged = '0';
              options.onSuccess({ event: 'stdoutData', stdoutString: 'Applied 120 selected CA certificates.' });
              options.onSuccess({ event: 'exit', exitCode: 0 });
              return;
            }
            if (action === 'restore') {
              window.__manager.active = '0';
              window.__manager.mounted = '0';
              window.__manager.boot_checks = '0';
              window.__manager.active_sha256 = '';
              window.__manager.certificate_count = '0';
              options.onSuccess({ returnValue: true, stdoutString: 'Restored stock trust.' });
              return;
            }
            if (command.indexOf(' boot-checks ') !== -1) {
              window.__manager.boot_checks = action === 'on' ? '1' : '0';
              options.onSuccess({ returnValue: true, stdoutString: 'Boot-time checks updated.' });
              return;
            }
            options.onSuccess({ returnValue: false, error: 'Unexpected helper action.' });
          } } };
        """)
        page.add_init_script("""
          Object.defineProperty(window, 'webOS', {
            configurable: true,
            get: function () { return this.__mockWebOS; },
            set: function (value) { this.__realWebOS = value; }
          });
        """)
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(app)
        page.wait_for_load_state("networkidle")
        page.wait_for_function("document.getElementById('connection-label').textContent === 'Root service ready'")

        assert page.get_by_role("heading", name="CA Bundle Manager").is_visible()
        assert page.get_by_role("button", name="Apply selected roots").is_visible()
        assert page.get_by_role("button", name="Enable boot-time checks").is_visible()
        assert page.get_by_role("button", name="Restore stock trust").is_visible()
        assert page.locator("#source-mozilla").is_checked()
        assert page.locator("#custom-path").is_disabled()

        page.get_by_text("Custom PEM file", exact=True).click()
        assert page.locator("#custom-path").is_enabled()
        page.get_by_text("Custom PEM file", exact=True).click()
        assert page.locator("#custom-path").is_disabled()

        page.locator("#apply-button").evaluate("element => element.focus()")
        assert page.evaluate("document.activeElement.id") == "apply-button"
        assert page.evaluate("document.documentElement.scrollWidth") <= 1920
        assert page.evaluate("document.documentElement.scrollHeight") <= 1080
        screenshot = Path(gettempdir()).resolve() / "ca-bundle-manager-smoke.png"
        page.screenshot(path=str(screenshot), full_page=True)

        page.on("dialog", lambda dialog: dialog.accept())
        page.get_by_text("Chrome Root Store", exact=True).click()
        page.get_by_text("Custom PEM file", exact=True).click()
        page.locator("#custom-path").fill("/media/developer/custom CA; safe.pem")
        page.get_by_role("button", name="Apply selected roots").click()
        page.wait_for_function("document.getElementById('active-indicator').textContent === 'APPLIED'")
        assert page.locator("#certificate-count").inner_text() == "120"
        assert page.locator("#custom-path").input_value() == "/media/developer/custom CA; safe.pem"
        assert "/media/developer/custom CA; safe.pem" not in page.evaluate("window.__manager.selection")

        page.get_by_role("button", name="Enable boot-time checks").click()
        page.wait_for_function("window.__manager.boot_checks === '1'")
        assert page.get_by_role("button", name="Disable boot-time checks").is_visible()

        page.get_by_role("button", name="Restore stock trust").click()
        page.wait_for_function("document.getElementById('active-indicator').textContent === 'STOCK'")
        assert page.locator("#active-hash").inner_text() == "Not applied"
        assert page.locator("#connection-status").get_attribute("class") == "status-chip connected"
        assert not errors, errors
        browser.close()

    print(f"UI browser smoke test passed at 1920x1080; screenshot: {screenshot}")


if __name__ == "__main__":
    main()
