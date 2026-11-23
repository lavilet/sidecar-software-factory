# Operate the factory

```sh
factory run --help
factory bot --help
factory attach TASK_ID --print
factory dashboard --port 4127
```

Set `FACTORY_PROJECT` to the target checkout in each shell. Set the same `FACTORY_STATE_DIR` if you chose a custom location. Run one bot per target. The dashboard binds to loopback and exposes local logs, prompts and evidence to its clients.

## GitHub setup

Configure the target's `origin` for the intended GitHub repository, authenticate Git for pushing, and authenticate `gh` under the operator account. Use a trusted target and trusted contributors to its agent queue. The worker runs repository commands and the verify hook executes candidate code with your local account's permissions. Use a disposable development environment for untrusted changes.

```sh
git -C "$FACTORY_PROJECT" remote get-url origin
(cd "$FACTORY_PROJECT" && gh repo view --json nameWithOwner,defaultBranchRef)
factory setup-labels
factory bot --dry-run
factory bot --loop --interval 60
```

A live bot needs access to read and write issues, review comments, branches and draft PRs. `--dry-run` inspects queues using GitHub. `--no-pr` suppresses normal PR creation but the live bot still manages issue labels and comments. A single local `factory run` is the entry point for an isolated trial. Add `--base BRANCH` to select the delivery base explicitly.

| Label | Meaning |
| --- | --- |
| `agent:triage` | Ask the router to draft acceptance criteria and a stop condition |
| `agent:needs-info` | Answer questions and restore triage, or approve the contract by setting ready |
| `agent:ready` | Queue for dispatch |
| `agent:waiting-deps` | Wait for the listed GitHub issues to close |
| `agent:in-progress` | Work is running in a separate worktree |
| `agent:blocked` | Inspect the logs, resolve the blocking condition and restore ready to retry |
| `agent:review` | Draft PR open for human review. Submitted reviews trigger follow-up work |
| `agent:merged` | The operator merged the PR and the bot recorded the outcome |
| `agent:epic` | Parent context shared with child tasks |

Add `--auto-approve` to dispatch eligible low- and medium-risk triage decisions without manual contract approval. Add `--auto-retro` to analyze merged outcomes. Pilot merges trigger retro even without this flag. Retro can open improvement issues during the bot's merge callback. `factory retro --propose-pr` delegates the top upgrade as a target PR. `factory scout --create-issues` publishes proposals.

## Epics and review

Mark the parent issue `agent:epic` and use `factory split-epic 12` to inspect a proposed split. This reads the issue and calls the router. Add `--create` to write child issues, or `--create --pilot-only` to create the pilot. Child bodies use `Parent: #12`, `Depends on: #13` and optional `Pilot: true`. The bot reads dependency state from GitHub on each tick. Merge completed work on GitHub. The bot observes the merge and records differences between the agent head and the merged source.

## Verification, evidence and recovery

`factory verify` runs the project gate in the selected main checkout. During delivery the runner executes the same hook in the candidate worktree. For debugging, run `(cd "$worktree" && "$profile/hooks/verify")` with the paths from the run. Verification failures return the check output to the worker. After bounded retries the run stops and preserves its files. Hooks should print actionable failure output, exit nonzero on failure and work from fresh clones.

`factory run --qa` plans and executes a scenario from the task and diff. Pass `--qa-scenario` with an absolute path for a fixed scenario. The bugfix playbook runs the same scenario before and after the change. A planned scenario can be corrected once after a selector failure. Screenshots and recordings remain in the profile by default. `--upload-evidence` can push media to the target's `harness-evidence` branch and attach videos to a PR when the installed GitHub CLI supports attachments. Use synthetic data suitable for your target's audience.

Rerun a task with its original ID to reuse saved stages. Check `pipeline.log`, `checkpoint.json`, `sessions.json` and `metrics.json` in its run directory. When adjusting a failed candidate, `factory attach TASK_ID --print` shows the recorded backend session. Use `--fresh` to rerun the stages on the current candidate. A rebase conflict leaves the worktree for inspection. Resolve it and repeat the run. Review both the target's branch list and the linked worktree list before removing completed worktrees.

```sh
git -C "$FACTORY_PROJECT" worktree list
profile="$(factory profile)"
git -C "$profile/worktrees/TASK_ID" status --short --branch
git -C "$FACTORY_PROJECT" worktree remove "$profile/worktrees/TASK_ID"
```

Replace `TASK_ID` with a finished task. Ordinary `git worktree remove` refuses to discard uncommitted edits. Remove an obsolete branch with normal Git branch management after its work has been integrated. Keep the profile for its rules and run history.
