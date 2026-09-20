# AGENTS.md

Rules for agents working in this repository.

## Submission-like operations

These operations all count as submissions and need explicit approval, asked separately each time:

- `git commit` (including `--amend`), `git merge`, `git rebase`, `git cherry-pick`;
- `git push` (including force push), `git tag` / pushing tags;
- destructive operations such as `git reset --hard`, `git checkout -- .`, `git clean -fd`, `git stash drop`;
- any `gh` / `git` command that creates or changes remote state (PRs, releases, ...).

Request that approval with `ask_user_question`, and state whether untracked files will be `git add`ed and that the commit will be GPG-signed. A vague reply ("whatever", "do as you like") does not count as approval.

Never submit from a background job or a script: no background tasks, chained `&&` commands, hooks, or wrapper scripts to get around the approval, and no auto-committing just to keep a workflow moving.

Everything that is not a submission — editing code, running builds and tests, reading `git diff` / `git log` — needs no approval.

## GPG signing

- This repo is configured with `user.signingkey = 7886F2AB95ADBCE2`, `commit.gpgsign = true`, `gpg.format = openpgp`. Pass `-S` explicitly anyway (e.g. `git commit -S -m "..."`); do not rely on ambient defaults.
- Also off-limits: `-c gpg.program=/bin/true` or similar, forging, stripping, or rewriting a signature after the fact, and "commit first and sign later". Do not rebase or amend pre-existing unsigned commits to add signatures unless the user explicitly asks.
- Verify with `git verify-commit HEAD` (or `git log -1 --format='%G?'`): the result must be `G`. `N` (no signature), `B` (bad signature), `E` (key unavailable) and the like mean the commit failed.
- GPG needs to write `~/.gnupg` (gpg-agent socket, trustdb, lock files, random_seed), which the default `workspace-write` file sandbox denies on this machine (observed: `Operation not permitted` / `can't connect to the gpg-agent`). Commits therefore usually need a `danger-full-access` escalation whose justification says "needs write access to ~/.gnupg to sign the commit"; that approval prompt is the confirmation for that one commit.
- `tag.gpgsign` is not configured, so tags must be created with `git tag -s` and verified with `git tag -v <tag>`.
- After a commit, report the commit hash, the full commit message, and the `git verify-commit` result (e.g. `G`, signer `acehinnnqru <acehinnnqru@gmail.com>`).

## Private material stays outside the repo

**Never copy private or sensitive user material into the repository or the workspace.**

- Especially (not exhaustive): `~/.gnupg` (including `pubring.kbx`, `private-keys-v1.d`, `trustdb.gpg`), SSH private keys, `~/.dsh/.credentials.yaml`, `~/.dsh/.env`, `settings.yaml`, browser data, any token or certificate. **"It's only a public key" is not an excuse.** A past agent copied `~/.gnupg/pubring.kbx` into `.scratch/gnupg/` to verify signatures — that is exactly the forbidden pattern.
- Never work around the sandbox by copying. When the file sandbox blocks something (for example gpg needs to write `~/.gnupg`), there are only two options: request an escalation via `sandbox_permissions` with a justification for the user to approve, or stop and ask the user. "Copy it somewhere writable and run from there" is not allowed.
- Reading private files: prefer an escalated read of the original location, produce no copies, and do not write the contents into logs, commits, or any repository file.
- Do not touch the user's global configuration. Without explicit approval, do not modify `git config --global`, `~/.gnupg`, `~/.dsh/settings.yaml`, shell configuration, or anything else outside the repository.

## Scratch files

If a scratch file really must live in this tree, it goes under the gitignored `.scratch/`. At the end of a task, check `git status --short` so nothing extra is left behind (ask first when user-owned files are involved).
