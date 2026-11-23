# Frozen evaluations

Create a JSON file in `tasks/` and an executable file in `checks/`. The runner starts a fresh candidate at the full base commit, runs the task and invokes the named check from the candidate directory afterward. Both stages must pass. The check stays in the external profile. This is a workflow convention, not a separate filesystem sandbox.

For the bundled status-page example, run the following from its target checkout with `FACTORY_PROJECT` set and the factory on your PATH.

```sh
profile="$(factory profile)"
mkdir -p "$profile/evals/tasks" "$profile/evals/checks"
cat > "$profile/evals/tasks/footer.json" <<EOF
{
  "id": "footer",
  "base_sha": "$(git rev-parse HEAD)",
  "playbook": "feature",
  "brief": "Add a footer containing Status updates to the home page.",
  "done_if": "index.html has a footer with the text Status updates.",
  "check": "footer"
}
EOF
cat > "$profile/evals/checks/footer" <<'SH'
#!/bin/sh
set -eu
grep -Eq '<footer[^>]*>Status updates</footer>' index.html
SH
chmod +x "$profile/evals/checks/footer"
factory eval --filter footer
```

Use `--update-baseline` to save the summary in this directory. Each run keeps its logs and removes its disposable eval worktree and branch.
