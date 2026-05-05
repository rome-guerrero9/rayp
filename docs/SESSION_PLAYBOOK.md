# Session Playbook

Three commands at the start, three at the end. That's it.

## Start of session

```bash
cd ~/rayp
git fetch origin --prune
git checkout master && git pull --ff-only origin master
cat docs/PROJECT_STATUS.md
```

If `PROJECT_STATUS.md` says you're mid-something, resume from the "Open work items" section. If the candidate values still say "unverified," verifying them is the first thing to do.

## End of milestone

For any deploy, audit reply, post published, multisig action, or other off-chain milestone:

```bash
# 1. Edit docs/PROJECT_STATUS.md — flip the relevant row, add a dated note
# 2. Commit and push:
git add docs/
git commit -m "docs: <short summary of milestone>"
git push origin <current-branch>
```

If you're on a feature branch, open or update the PR. If you're on master and the change is just a doc update, pushing direct is fine.

## What never lives in chat-only memory

- Deployed contract addresses → `docs/SEPOLIA_DEPLOYMENT.md`
- Multisig addresses and roles → `docs/MULTISIG.md`
- Audit submissions / replies → `docs/AUDIT_SCOPE.md` + `docs/AUDIT_COVER_EMAIL.md`
- Forum / mirror / grant posts → respective `docs/*.md`
- Open tasks → GitHub Issues (or `PROJECT_STATUS.md` if too small for an issue)

If something only exists in a Claude conversation or on one device, it doesn't exist.

## Cross-device discipline

- Pull before editing. Always.
- Commit + push before closing a session, even if the work is partial — leave a `WIP:` commit if you must.
- Branch names matter: long-running branches survive across devices, ad-hoc local branches don't.
