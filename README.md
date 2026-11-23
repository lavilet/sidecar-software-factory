# Sidecar Software Factory

Turn a GitHub issue or a local brief into a verified change in an isolated Git worktree. The factory lives in its own checkout. A project profile supplies the target's checks, conventions, playbooks and optional browser preview. The target can use any language or framework.

## Try it locally

```sh
git clone --branch codex/portable-harness https://github.com/lavilet/sidecar-software-factory.git
cd sidecar-software-factory
ruby -v
export FACTORY_RUBY="$(ruby -rrbconfig -e 'print RbConfig.ruby')"
export PATH="$PWD/bin:$PATH"
bin/smoke
```

Use macOS or Linux, Git, Ruby 3.2 or later, and Python 3.9 or later for the sample. The factory core uses the Ruby standard library. Pinning `FACTORY_RUBY` keeps the factory on that interpreter even if the target uses a different language runtime.

The smoke test creates two temporary Git repositories with the same name. It exercises initialization, a deterministic dry run, a scripted worker, two reviewers, local handoff, checkpoint recovery and a failing gate. It runs offline and cleans up its temporary files. Real agent runs use the provider CLI selected in the profile.

## Connect your repository

```sh
export FACTORY_PROJECT=/absolute/path/to/your-project
factory init
factory profile
factory verify
```

Choose a Git checkout with at least one commit. `factory init` creates missing profile files and preserves existing edits. The default verify hook runs the target's executable `./bin/check`. If the project uses another command, edit `hooks/verify` under the directory printed by `factory profile`. Use the same commands and working directory as the project's CI. A missing gate stops the run with a nonzero exit.

Give a local setup agent the [installation brief](docs/agent-setup.md). It covers runtime discovery, hooks, project-specific rules, the verification trial and the handoff. A complete [worked example](docs/status-page.md) uses the bundled static site.

```sh
factory run --task first-pass --playbook feature \
  --brief "Describe one small change in the target." \
  --done-if "Give a concrete observation or test that proves the change." \
  --dry-run
```

The dry run creates a worktree at the chosen base commit, writes the stage prompts, actually executes the verify hook, and writes a handoff summary. The main target checkout can contain other work. Only committed base content is available to a new candidate. For a real local run, authenticate the configured agent CLI on your machine and repeat the command without `--dry-run`. Add `--pr` to commit, push and open a draft PR on the target's remote.

## Where things live

| Location | Contents |
| --- | --- |
| Factory checkout | CLI, orchestration code, JSON schemas, recorder, starter profiles and examples |
| `$(factory profile)/` | Per-target configuration, editable rules, verification and preview hooks |
| `$(factory profile)/worktrees/<task>/` | Candidate checkout attached to the target's branch `harness/<task>` |
| `$(factory profile)/runs/<task>/` | Plan, prompts, verification logs, verdicts, session IDs, QA media and PR text |
| `$(factory profile)/runs/` | Bot state, issue records, telemetry and retrospectives |
| Target repository | Application source, its normal development tools and Git's linked-worktree metadata |

Profiles default to the factory's ignored `projects/` directory. Set `FACTORY_STATE_DIR` to an absolute directory outside the target to keep state elsewhere, for example on a persistent disk. The key uses the target's canonical checkout path. Moving or recloning a target creates a new profile. Keep the same factory and state paths while linked worktrees are active. Run artifacts can contain source diffs, prompts, tool output and screenshots. Keep profiles private and use local CLI authentication.

## Delivery flow

1. **Triage.** The router translates the issue into acceptance criteria, risk, a playbook, a verifiable stop condition and a browser QA decision. A human can refine the contract.
2. **Plan and implement.** A read-only architect maps the work. The worker edits the isolated candidate. Failed verification output goes back to the worker within the retry limit.
3. **Verify and review.** The project hook runs from the candidate directory. Optional browser QA records the candidate on mobile and desktop. Two independent sessions review the diff. An arbiter resolves disputed findings. On an explicitly requested draft PR, limited split verdicts can reach human review with a warning.
4. **Handoff.** The runner writes `pr-body.md`. A publishing run syncs with the base, rechecks a rebased candidate and opens a draft PR. The GitHub bot can resume work after submitted review feedback.
5. **Learn.** A merge can trigger a retrospective using the review history and telemetry. Scout proposes improvements. Frozen evals replay work at a pinned commit and run a held-out executable check.

Reuse the task ID and contract to resume after a failure. Use `--fresh` to discard stage checkpoints and rerun stages on the existing worktree. Use a new task ID for a separate candidate. The default profile uses the installed Codex CLI's model for every role, including two independent reviewer calls. Override per-role backends, models and effort in `config.toml`. Gemini and Antigravity CLI adapters are also included. Model pricing is operator-supplied. The starter zero rate yields zero estimates until configured.

## Commands

Use `factory --project PATH COMMAND` or export `FACTORY_PROJECT` once. Run `factory run --help` for task options.

| Command | Behavior |
| --- | --- |
| `factory init`, `factory profile` | Create a profile or print its absolute path |
| `factory verify` | Run the profile hook in the selected target checkout |
| `factory run --task ID --brief TEXT --done-if TEXT` | Execute the local delivery pipeline |
| `factory attach ID --print` | List sessions and takeover commands |
| `factory dashboard` | Open the local run server at `http://127.0.0.1:4127` |
| `factory qa` | Run the configured browser preview and default scenario |
| `factory setup-labels` | Create or update the workflow labels on the target GitHub repository |
| `factory bot --dry-run` | Read GitHub queues and show what a tick would dispatch |
| `factory bot --loop --interval 60` | Process issues, publish draft PRs and handle submitted reviews |
| `factory split-epic 12` | Read an epic and generate a child plan. Add `--create` to create the issues |
| `factory retro`, `factory scout` | Analyze previous outcomes or inspect the target and suggest improvements |
| `factory eval` | Run configured frozen tasks and compare against a saved baseline |

The [operator guide](docs/operations.md) covers GitHub permissions, state transitions, evidence publishing, dependencies, pilot issues, retries and cleanup.
