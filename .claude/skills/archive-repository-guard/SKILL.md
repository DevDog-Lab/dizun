---
name: archive-repository-guard
description: Enforce public MIT GitHub repository safety, secret-free commits, approval-gated pushes, release controls, upstream attribution, and GitHub Pages publishing for DIZUN. Use for every Git, GitHub, dependency, website, CI, packaging, and release change.
---

# DIZUN: public repository guard

Applies **only to DIZUN** (`DevDog-Lab/dizun`, `/Volumes/Development/DevDog-Lab/dizun`). Read root `CLAUDE.md`, `docs/PUBLICATION_POLICY.md`, and `docs/SPEC.md` before work. Orca orchestrates; Claude Code implements; Codex is an exception for difficult blockers.

## Absolute rules
1. **Never put real secrets or private materials in Git**, including API keys, auth tokens, passwords, `.env` (including variants), credentials, certificates with private keys, SSH/GPG private keys, provisioning profiles, Apple signing keys, cloud service files, or session cookies. Do not include them in source, examples, fixture archives, logs, tests, README, generated website, screenshots, commit messages, branches, tags, or Git history.
2. **Local commits are allowed at any time**, after staged-file audit and scan. **No push, PR, GitHub Pages activation, release, publication, distribution, or remote mutation** without the user's explicit, action-specific instruction. Never interpret general project approval as approval to publish or push. Do not auto-push or turn on push-on-commit.
3. **Do not bypass safeguards** by `--no-verify`, disabling hooks, force-pushing, removing scans, bypassing GitHub push protection, or disabling branch rules. If blocked, stop and report redacted findings; ask user before changing enforcement.
4. Build and test offline at runtime. No tracking, advertising, analytics, update polling, external CDNs, remote fonts, or third-party scripts on public site.
5. Existing OSS requires license verification, attribution, provenance/commit SHA recording, and license compatibility review. **MIT of this project does not erase upstream obligations**. Document bundled notices and any GPL/LGPL/unRAR obligations before distribution.
6. Never log or echo secret values. If suspected exposure: stop publication, do not paste secret in chat, rotate/revoke credential, remove from working tree and **all affected commit history**, run full historical scan before further approval.

## Before every local commit
- `git status --short` and `git diff --cached --name-status`; inspect all staged files (including binary/archive/image artifacts, symlinks, generated files).
- Run `python3 scripts/repo_guard.py staged`; fix all findings before committing. Run `gitleaks git --redact --exit-code 1` if installed; if absent, record a warning (not a clean scan).
- Ensure `.gitignore` guards are present and use only obviously fake placeholder values in examples.
- Commit only intended files; include a compact outcome report.

## Before a user-approved push or publication
- Verify the user's explicit instruction names the action and destination; treat approval as single-use and scoped.
- Run `python3 scripts/repo_guard.py history` and `gitleaks git --redact --exit-code 1` (install gitleaks if missing). Review `git log --all`, tags, branch names, tracked binary assets, website source, and any workflow permissions.
- Confirm no tokens in remote URLs (`git remote -v` output must be redacted), no unreviewed artifacts, no secret-containing LFS objects, and no unintended commit range.
- Require user approval for any GitHub remote write; then push only the approved branch/ref. Do not auto-publish the website, release artifacts, or create a repo as a side effect.
- Recommend enabling GitHub secret scanning + push protection, but never claim they catch every secret.

## Website and README
- Public-facing docs describe verified features only; label planned features clearly.
- No external analytics, trackers, forms, unapproved images/logos, personal email addresses or secrets.
- Keep `site/index.html`, `README.md`, `SECURITY.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md` aligned. Site publishing is a separate approval gate.

## When uncertain
Prefer blocking the operation and reporting the reason over a false clean bill of health. Rules in this skill supplement root CLAUDE.md and cannot override explicit user approval requirements.

## DIZUN-specific identity
- Brand source: `docs/DIZUN_BRAND_CONCEPT.md`. Do not claim the proposed tagline or logo is final.
- Repo already exists remotely; do not create it again. Read and preserve the existing local repo before importing this bundle.
