# Publishing to a public repo

`llatser-dot/beers` is **public**. Read this before pushing anything derived
from real usage, before committing a generated file, and before flipping any
other repo public. It is not required reading for ordinary code work.

## The one thing to understand

A public repo publishes its **history**, not its current state. Deleting a file
in a new commit removes nothing — the blob is still reachable from the commit
that added it, and from every branch and tag that descends from it:

```sh
git show <old-commit>:path/to/deleted-file    # still works, forever
```

Tags are the trap. They are separate refs, so `git push --force origin main`
leaves every tag still serving the old blobs. This has now bitten this repo
twice.

## What may and may not enter the repo

The line is not "secret vs not secret". It is **code vs data**.

| Fine to commit | Never commit |
|---|---|
| Source, scripts, configs | Real dictations / transcripts, verbatim |
| Design docs, decisions, architecture | Client names, customer rosters, people's names |
| Renames, refactors, embarrassing bug fixes | Business plans, revenue, internal strategy |
| Metrics: precision, recall, counts, verdicts | Credentials, tokens, private URLs |
| Transcript **IDs** (`gold-035`) | Transcript **text** |

Commit messages, branch names and author emails are public too. That is fine —
a rename or a bug fix tells nobody anything. Leaked data is the actual risk.

## Already enforced

- `ml/data/` — real speech and derived training data, gitignored.
- `ml/standing-loop/report-*.md` — retrain reports quote real dictations
  verbatim by design, gitignored. See `RETRAIN-PROMPT.md`.
- `ml/standing-loop/*.log`, `state.json` — gitignored.

## Before committing a generated file

Generated files are where leaks come from, because nobody reads them.

1. **Read it.** Not a skim — actually look at what the generator emitted.
2. Grep it for names, clients, credentials, and whole sentences of real
   user input.
3. Ask whether it is derived from real usage data. If yes, default to
   gitignoring it and committing a metrics-only summary instead.
4. Fix the **generator**, not just the output — it runs again next week.

## If something private has already been pushed

1. **Do not just delete it in a new commit.** That fixes nothing.
2. Check every ref, not just `main`:
   ```sh
   for r in $(git for-each-ref --format='%(refname:short)'); do
     git cat-file -e "$r:<path>" 2>/dev/null && echo "$r contains it"
   done
   ```
3. Back up first: `git clone --mirror . ../backup.git`
4. Remove worktrees (they block the rewrite), then:
   ```sh
   git filter-repo --invert-paths --path <path> --force
   ```
5. `filter-repo` deliberately drops the `origin` remote. Re-add it, then push
   **branches and tags**:
   ```sh
   git remote add origin <url>
   git push origin --force --all
   git push origin --force --tags
   ```
6. Verify from a **fresh clone**, not your local repo — your local copy can
   look clean while the remote is not.
7. Rotate anything that was a credential. A rewrite is not a guarantee:
   GitHub may serve the old commit by direct SHA for a while, and anyone who
   already cloned or forked still has it.

The window for a clean rewrite closes the moment someone forks you. Check
`gh repo view <repo> --json forkCount,stargazerCount` — if it is still zero,
a rewrite is genuine cleanup rather than damage control.
