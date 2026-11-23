# Try a standalone status page

Run from the factory checkout in the same shell as the README setup. This creates a separate Git target and an external profile under a temporary directory.

```sh
demo_dir="$(mktemp -d)"
cp -R examples/status-page "$demo_dir/status-page"
export FACTORY_PROJECT="$demo_dir/status-page"
export FACTORY_STATE_DIR="$demo_dir/profiles"
git -C "$FACTORY_PROJECT" init -b trunk
git -C "$FACTORY_PROJECT" add .
git -C "$FACTORY_PROJECT" -c user.name=Demo -c user.email=demo@example.invalid commit -m "Add status page"
factory init
factory verify
factory run --task home --brief "Check the status page." \
  --done-if "The Service status heading passes the project check." --dry-run
profile="$(factory profile)"
cat "$profile/runs/home/verify-dry-run.log"
```

The target is a single HTML page with an executable Python check. Its entry point is `index.html`, its contract is one `h1` with the text `Service status`, and its verifier is `bin/check`. The run creates `harness/home` off `trunk`. The application checkout stays on `trunk`.

## Record a browser scenario

```sh
python3 -m venv "$demo_dir/browser-env"
export FACTORY_PYTHON="$demo_dir/browser-env/bin/python"
"$FACTORY_PYTHON" -m pip install playwright
"$FACTORY_PYTHON" -m playwright install chromium
cp "$profile/hooks/serve.example" "$profile/hooks/serve"
chmod +x "$profile/hooks/serve"
"$FACTORY_PYTHON" - "$profile/qa/default.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
scenario = json.loads(path.read_text())
scenario["steps"].insert(1, {"action": "expect_text", "text": "Service status"})
path.write_text(json.dumps(scenario, indent=2))
PY
factory qa --root "$profile/worktrees/home"
cat "$profile/runs/qa-manual/qa/qa-report.json"
```

The preview runs on a dynamically chosen loopback port. The recorder produces a WebM recording and a screenshot for each viewport. With FFmpeg on PATH it also produces MP4 and GIF files. For Linux hosts missing Chromium system dependencies, use the dependency setup appropriate for your distribution.

## Exercise a real worker

```sh
factory run --task status-update --playbook feature \
  --brief "Change the status message to All systems ready. Preserve the heading." \
  --done-if "The home page shows All systems ready. and bin/check passes."
git -C "$profile/worktrees/status-update" diff
cat "$profile/runs/status-update/pr-body.md"
```

This last step calls the configured agent provider and keeps the result local. Use `factory dashboard` in a separate terminal to inspect the run. See the evaluation recipe in [the profile template](../templates/profile/evals/README.md) to replay a task at a fixed commit.
