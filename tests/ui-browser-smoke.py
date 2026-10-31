from pathlib import Path
from tempfile import gettempdir

from playwright.sync_api import sync_playwright


def main():
    app = (Path(__file__).resolve().parents[1] / "index.html").as_uri()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1920, "height": 1080})
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.goto(app)
        page.wait_for_load_state("networkidle")

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

        page.locator("#apply-button").focus()
        assert page.evaluate("document.activeElement.id") == "apply-button"
        assert page.evaluate("document.documentElement.scrollWidth") <= 1920
        assert page.evaluate("document.documentElement.scrollHeight") <= 1080
        screenshot = Path(gettempdir()) / "ca-bundle-manager-smoke.png"
        page.screenshot(path=str(screenshot), full_page=True)

        page.wait_for_function("document.getElementById('connection-status').classList.contains('error')")
        assert "Homebrew root service unavailable" in page.locator("#connection-label").inner_text()
        assert not errors, errors
        browser.close()

    print(f"UI browser smoke test passed at 1920x1080; screenshot: {screenshot}")


if __name__ == "__main__":
    main()
