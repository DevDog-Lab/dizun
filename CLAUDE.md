# CLAUDE.md — DIZUN

## Mission
Develop **DIZUN（ディズン）**, a privacy-first native macOS compression/extraction app with reliable Japanese filename handling and Windows interoperability. Read `docs/DIZUN_BRAND_CONCEPT.md` for the canonical brand story and `docs/SPEC.md` for full requirements.

## Collaboration
- Orca orchestrates all work. Claude Code is the primary agent for research, design, code, tests and local commits.
- Invoke Codex only for a clearly identified difficult blocker or independent review; package a precise question with reproduction and evidence. Claude Code owns verification and integration.
- Keep updates concise: decision, files changed, tests and evidence, blockers, next step.

## Guardrails
- Never `git push`, create a remote repository, open a PR, publish, notarize or distribute without explicit user approval. Local commits are allowed.
- Do not change Finder defaults or uninstall/modify other archive apps.
- Runtime must have no telemetry, advertisements, analytics, update-check network calls or external APIs. Development-time dependency fetching is distinct.
- During normal extraction do not mutate extracted file contents. Text transcoding must be a separate opt-in operation.
- Never silently overwrite existing files. Validate archive paths against traversal, links and name collisions. Bound archive expansion and resource usage.
- Do not assert archive compatibility until tested using specific Windows/macOS versions.
- Preserve upstream license and attribution notices; audit transitive dependencies and pin upstream SHAs.

## First execution sequence
1. Inspect local macOS, Xcode/CLI tools, Swift, existing workspace, git state; do not edit unrelated projects. Work only in `/Volumes/Development/DevDog-Lab/dizun`; check existing files and git status before merging. GitHub remote is `https://github.com/DevDog-Lab/dizun.git` (created by user); never overwrite or reset history.
2. Read `docs/SPEC.md`. Fetch upstream references into a separate research area, pin SHAs, inspect license/source/build setup.
3. Write `docs/OSS_AUDIT.md`, `docs/BASELINE.md`, `docs/ARCHITECTURE_DECISION.md` based on verified findings. Don't assume Crate is the right base without evidence.
4. Implement the smallest functioning ZIP create/extract core with fixtures and safety tests, then expand toward Finder integration.
5. Record results and decisions in `docs/WORK_LOG.md`; make coherent local commits and report their SHAs.

## Definition of done for the first milestone
- Audits and architecture decision have actual evidence; baseline build/test results are reproducible.
- Minimal code builds and tests pass or failures are precisely documented.
- No remote writes and no system-wide association changes.

## Mandatory project-specific publication guard (v0.3)
- Read and apply `.claude/skills/archive-repository-guard/SKILL.md` and `docs/PUBLICATION_POLICY.md` **for all work touching Git/GitHub, CI, docs, website, release or secrets**. Do not depend on automatic skill selection; explicitly read when relevant.
- The user has created the GitHub repository `DevDog-Lab/dizun`; it is intended to be public and MIT-licensed. **Creating it is no longer a task, and this does not authorize any push, remote modification, PR or Pages deployment.**
- Local commits are allowed after `python3 scripts/repo_guard.py staged`. Before any approved push, require historical gitleaks scan and user-specific approval. Do not use `--no-verify` or bypass checks.
- Maintain the project-specific Git hook via `git config core.hooksPath .githooks` when working in this repo (local-only), and do not auto-authorize pushes.
- The public landing page is staged locally in `site/index.html`; GitHub Pages activation requires separate explicit approval.

## Source of truth / safety
- Identity and concept: `docs/DIZUN_BRAND_CONCEPT.md`; do not treat optional tagline or logo as approved.
- Do not destroy or rewrite the existing local Git history. Keep existing `.git` and check remotes; if there is a non-empty remote history, reconcile without forced pushes.
- Neither commit nor print actual secrets. If any are discovered, stop and redact reports.
