# DIZUN public MIT repository policy — v0.4

## Roles and permissions
- Orca orchestrates. Claude Code is primary developer and may commit locally. Codex is limited to hard blockers / independent review.
- **Default deny:** git push (including `--tags`, `--mirror`, `--force`, REST/GraphQL remote writes), PR creation, release, website deployment, Pages activation, signing/notarization, public distribution, remote secrets creation, and CI workflow enabling. Require **explicit user authorization separately for each action**.
- User approval for one push does not authorize future pushes or any other GitHub action.

## Forbidden materials — all tracked content and history
- Real secrets: API keys, tokens, access credentials, passwords, OAuth grants, session cookies, keys, signing identities.
- `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.p8`, `id_rsa`, `id_ed25519`, credential and config dumps; no true values in `*.example` either.
- Personal, customer, production data and private log/backup databases; archive test fixtures must be synthetic and inspected.
- Obfuscation, base64, screenshots, PDFs, ZIPs and compiled assets are **not exemptions**. Review binary contents manually or omit them.
- A `.gitignore` entry is not sufficient: check staged content **and Git history**.

## Defense in depth
1. `.gitignore` restricts accidental additions.
2. `.githooks/pre-commit` scans staged data, including names; fails closed if script unavailable.
3. `.githooks/pre-push` denies pushes unless an explicit local, per-command approval variable is set **after obtaining user approval**. This is a friction gate, **not** a cryptographic proof of approval.
4. `scripts/repo_guard.py` catches common filename and token patterns, not all secrets.
5. **gitleaks full history audit mandatory before approved pushes**. If unavailable, do not push.
6. Enable GitHub secret scanning and push protection for the already-created repository; independently review detections and do not bypass alerts.
7. Protect release workflows, use read-only `GITHUB_TOKEN` permissions by default, pin third-party actions to commit SHAs after inspection.

## Safe workflow
- For ordinary work: stage intentional files -> scan -> local commit -> report SHA and changes.
- For publication: user explicitly authorizes exact target and action -> enumerate commits/objects -> historical scan + manual audit -> perform only the approved action -> report output.
- Never print secrets or secret-containing diagnostic data. If discovered, notify via redacted description, revoke/rotate, clean all history, re-audit, and seek new authorization.

## License and third party
- Project license MIT. `LICENSE` may use generic contributor attribution until the user chooses final holder text.
- Audit and record upstream licenses and redistribution terms before copying any source code or binary. Preserve notices; document in `THIRD_PARTY_NOTICES.md`.
- The MIT project license does not automatically relicense third-party code. If license incompatibility or patent/codec limitations arise, stop distribution pending review.

## Website
- Site source: `site/index.html` (static, no dependencies). This is **a prepared local page, not a live website**.
- Publish with GitHub Pages only after separate user direction. Do not promise product capabilities until tested.
- No third-party telemetry/CDN/fonts/scripts, sign-up forms, user tracking or invented URLs. Public contact/issue links only after repo slug is confirmed.

## Fixed repo facts
- Repository created by user: `https://github.com/DevDog-Lab/dizun.git`. This does **not** grant push or remote-edit permission.
- Local working tree: `/Volumes/Development/DevDog-Lab/dizun`; preserve files and history.
- GitHub Pages source and site publishing remain local-only until a separate explicit approval.
