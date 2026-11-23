# Install the factory for a target

```sh
export FACTORY_ROOT=/absolute/path/to/sidecar-software-factory
export FACTORY_PROJECT=/absolute/path/to/target
export FACTORY_RUBY="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
export PATH="$FACTORY_ROOT/bin:$PATH"
"$FACTORY_RUBY" -v
git -C "$FACTORY_PROJECT" rev-parse --show-toplevel
git -C "$FACTORY_PROJECT" status --short --branch
git -C "$FACTORY_PROJECT" log -1 --oneline
factory init
profile="$(factory profile)"
```

Use this brief as the assignment for the installation agent. Deliver a passing local dry run against the named target and a short operator handoff. The factory and target should be separate checkouts. Keep the target's working files intact during installation.

1. **Discover the real commands.** Read the target's README, contributor instructions, package manifests and CI workflow. Identify runtime versions, dependency installation, generated assets and required test services. Verify that the checkout has a commit and that the selected base contains the necessary code.
2. **Wire the deterministic gate.** Edit `$profile/hooks/verify` as an executable script. It runs with the candidate worktree as its current directory. Use the target's actual CI command with nonzero exit on failure. If each fresh worktree needs dependency preparation, put repeatable setup in the hook or call the target's existing setup command. Prefer lockfile-based installs. Use only disposable test data. Optional failure classification can be printed as `[FAIL_CATEGORY=tests]`.
3. **Fill the project context.** Record actual repository-relative file paths in `rules/canonical-files.md`. Trace one real flow in `rules/golden-flow.md`. Put the target's ownership and error-handling conventions in `rules/patterns.md` and its contributor rules in `rules/index.md`. Adapt the feature, bugfix and review playbooks if the project needs different checks. Maintain path globs for human review in `protected-paths.txt`.
4. **Set role routing.** Use authenticated CLIs available to this user. Bare names such as `codex` use the provider default model. Specify `backend:model` to pin a model supported by that CLI. The `reviewers` value is comma-separated. Check the local CLI's help for support for structured output and headless execution. Keep credentials in the provider's normal local login or environment.
5. **Set up browser QA when applicable.** Configure an executable `hooks/serve` that starts the target from the current worktree, binds to `127.0.0.1`, reads `PORT` and stays in the foreground. Use `exec` to launch the server. Add any repeatable build or fixture setup that the preview requires. Replace `qa/default.json` and `qa/app-map.md` with a real public route, a stable selector and a visible success condition. For a CLI-only target use its verification hook for end-to-end checks.
6. **Prove the installation.** Run the commands below. Open `verify-dry-run.log` and confirm the expected target checks actually ran. Inspect the worker prompt for the target's conventions. For a web target run the configured browser scenario and inspect the recordings. Recheck the main target's Git status against the initial snapshot.

```sh
factory verify
factory run --task install-check --playbook feature \
  --brief "Verify the project's delivery setup." \
  --done-if "The project checks pass from an isolated worktree." --dry-run
cat "$profile/runs/install-check/verify-dry-run.log"
cat "$profile/runs/install-check/metrics.json"
git -C "$FACTORY_PROJECT" status --short --branch
```

**Handoff format.** Give the operator the target and profile paths, chosen base, exact verify and serve commands, measured results, artifact locations, and a runnable first task. Identify any external services or authenticated roles that still need a live run. Publishing a target change, running a continuous bot or changing GitHub labels is a separate operating step.
