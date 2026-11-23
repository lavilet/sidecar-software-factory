#!/usr/bin/env python3
"""Record deterministic mobile + desktop Playwright QA videos and screenshots.

Used by the optional browser QA stage.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from playwright.sync_api import sync_playwright


def convert_to_mp4(webm_path: Path, mp4_path: Path) -> bool:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg or not webm_path.exists():
        return False
    cmd = [
        ffmpeg,
        "-y",
        "-loglevel",
        "error",
        "-i",
        str(webm_path),
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(mp4_path),
    ]
    res = subprocess.run(cmd, capture_output=True)
    return res.returncode == 0 and mp4_path.exists()


def convert_to_gif(src_video: Path, gif_path: Path, max_width: int = 720) -> bool:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg or not src_video.exists():
        return False
    vf = f"fps=6,scale='min({max_width},iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer"
    cmd = [
        ffmpeg,
        "-y",
        "-loglevel",
        "error",
        "-i",
        str(src_video),
        "-vf",
        vf,
        "-loop",
        "0",
        str(gif_path),
    ]
    res = subprocess.run(cmd, capture_output=True)
    return res.returncode == 0 and gif_path.exists()


def find_cached_chromium():
    cache_roots = [
        Path.home() / "Library" / "Caches" / "ms-playwright",
        Path.home() / ".cache" / "ms-playwright",
    ]
    patterns = [
        "chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell",
        "chromium-*/chrome-mac*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "chromium-*/chrome-linux/chrome",
    ]
    for root in cache_roots:
        if not root.exists():
            continue
        for pattern in patterns:
            matches = sorted(root.glob(pattern), reverse=True)
            for match in matches:
                if match.is_file() and os.access(match, os.X_OK):
                    return str(match)
    return None


def launch_chromium(playwright):
    try:
        return playwright.chromium.launch(headless=True)
    except Exception:
        cached = find_cached_chromium()
        if cached:
            return playwright.chromium.launch(headless=True, executable_path=cached)
        raise


def run_viewport(playwright, base_url: str, viewport: dict, steps: list, out_dir: Path) -> dict:
    vp_name = viewport["name"]
    width = int(viewport["width"])
    height = int(viewport["height"])
    tmp_video_dir = out_dir / f".tmp-video-{vp_name}"
    tmp_video_dir.mkdir(parents=True, exist_ok=True)

    browser = launch_chromium(playwright)
    context = browser.new_context(
        viewport={"width": width, "height": height},
        record_video_dir=str(tmp_video_dir),
        record_video_size={"width": width, "height": height},
    )
    page = context.new_page()
    page.set_default_timeout(12000)

    console_errors = []
    page_errors = []
    http_5xx = []
    screenshots = []
    overflow_checks = []
    step_results = []
    failed_reason = None

    page.on("pageerror", lambda err: page_errors.append(str(err)))
    page.on(
        "console",
        lambda msg: console_errors.append(msg.text) if msg.type == "error" else None,
    )
    page.on(
        "response",
        lambda resp: http_5xx.append({"url": resp.url, "status": resp.status})
        if resp.status >= 500
        else None,
    )

    started = time.monotonic()
    try:
        for idx, step in enumerate(steps, start=1):
            action = step["action"]
            if action == "goto":
                url = base_url.rstrip("/") + step["path"]
                resp = page.goto(url, wait_until="networkidle")
                if resp is not None and resp.status >= 400:
                    raise AssertionError(f"GET {step['path']} returned HTTP {resp.status}")
                overflow = page.evaluate(
                    "() => ({ scrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth })"
                )
                if overflow["scrollWidth"] > overflow["innerWidth"] + 2:
                    overflow_checks.append(
                        {"path": step["path"], "scrollWidth": overflow["scrollWidth"], "innerWidth": overflow["innerWidth"]}
                    )
            elif action == "click":
                if step.get("selector"):
                    page.locator(step["selector"]).first.click()
                elif step.get("text"):
                    page.get_by_text(step["text"]).first.click()
                else:
                    raise AssertionError("click step requires selector or text")
            elif action == "fill":
                page.locator(step["selector"]).first.fill(step["value"])
            elif action == "select":
                page.locator(step["selector"]).first.select_option(step["value"])
            elif action == "press":
                if step.get("selector"):
                    page.locator(step["selector"]).first.press(step["key"])
                else:
                    page.keyboard.press(step["key"])
            elif action == "wait_selector":
                page.locator(step["selector"]).first.wait_for(state="visible")
            elif action == "wait_text":
                page.get_by_text(step["text"]).first.wait_for(state="visible")
            elif action == "wait_ms":
                page.wait_for_timeout(int(step.get("ms") or 400))
            elif action == "expect_text":
                body_text = page.locator("body").inner_text()
                if step["text"] not in body_text:
                    raise AssertionError(f"Expected text not found: {step['text']!r}")
            elif action == "expect_no_text":
                body_text = page.locator("body").inner_text()
                if step["text"] in body_text:
                    raise AssertionError(f"Unexpected text found: {step['text']!r}")
            elif action == "expect_selector":
                count = page.locator(step["selector"]).count()
                if count == 0:
                    raise AssertionError(f"Expected selector not found: {step['selector']!r}")
            elif action == "screenshot":
                shot_name = f"{vp_name}-{step['name']}.png"
                shot_path = out_dir / shot_name
                page.screenshot(path=str(shot_path), full_page=False)
                screenshots.append(str(shot_path))
            else:
                raise AssertionError(f"Unknown action: {action}")

            step_results.append({"step": idx, "action": action, "ok": True})
    except Exception as exc:
        failed_reason = str(exc)
        step_results.append({"step": len(step_results) + 1, "action": "error", "ok": False, "error": failed_reason})
        try:
            fail_shot = out_dir / f"{vp_name}-failure.png"
            page.screenshot(path=str(fail_shot), full_page=False)
            screenshots.append(str(fail_shot))
        except Exception:
            pass
    finally:
        video = page.video
        context.close()
        browser.close()

    webm_dest = out_dir / f"demo-{vp_name}.webm"
    mp4_dest = out_dir / f"demo-{vp_name}.mp4"
    gif_dest = out_dir / f"demo-{vp_name}.gif"
    video_path = None
    gif_path = None
    if video is not None:
        raw_path = Path(video.path())
        if raw_path.exists():
            shutil.move(str(raw_path), str(webm_dest))
            if convert_to_mp4(webm_dest, mp4_dest):
                video_path = str(mp4_dest)
            else:
                video_path = str(webm_dest)
            gif_width = 390 if width <= 500 else 760
            if convert_to_gif(Path(video_path), gif_dest, max_width=gif_width):
                gif_path = str(gif_dest)
    shutil.rmtree(tmp_video_dir, ignore_errors=True)

    passed = (
        failed_reason is None
        and len(page_errors) == 0
        and len(http_5xx) == 0
        and len(overflow_checks) == 0
    )

    return {
        "viewport": vp_name,
        "width": width,
        "height": height,
        "passed": passed,
        "duration_sec": round(time.monotonic() - started, 2),
        "failed_reason": failed_reason,
        "page_errors": page_errors,
        "console_errors": console_errors,
        "http_5xx": http_5xx,
        "horizontal_overflow": overflow_checks,
        "video_path": video_path,
        "gif_path": gif_path,
        "webm_path": str(webm_dest) if webm_dest.exists() else None,
        "screenshots": screenshots,
        "steps": step_results,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args()

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    if not scenario["steps"] or not scenario["viewports"]:
        raise ValueError("A scenario needs steps and viewports")
    names = [v["name"] for v in scenario["viewports"]]
    names += [s["name"] for s in scenario["steps"] if s["action"] == "screenshot"]
    if any(not isinstance(n, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", n) for n in names):
        raise ValueError("Use letters, numbers, underscores and hyphens in media names")
    for step in scenario["steps"]:
        if step["action"] == "goto" and not re.fullmatch(r"/(?!/)[^\\\\]*", step["path"]):
            raise ValueError("goto requires a local path that starts with a single slash")
    viewport_reports = []

    with sync_playwright() as p:
        for vp in scenario["viewports"]:
            report = run_viewport(p, args.base_url, vp, scenario["steps"], out_dir)
            viewport_reports.append(report)

    all_passed = all(r["passed"] for r in viewport_reports)
    summary = {
        "scenario": scenario["name"],
        "passed": all_passed,
        "viewports": viewport_reports,
    }

    report_path = out_dir / "qa-report.json"
    report_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps({"passed": all_passed, "report_path": str(report_path)}))
    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
