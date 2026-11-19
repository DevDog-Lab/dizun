# Contributing

This project is still in the architecture-validation phase. Before submitting patches, open a discussion or issue **after a public GitHub repository exists**.

- Never include real secrets, credential examples, real emails, user archive samples, account identifiers, or private files in issues, patches, tests, screenshots or logs.
- Use synthetic test ZIP fixtures. Prefer small, text-only files and test exact output hashes.
- Preserve originals on extraction; document compatibility behavior and test platform.
- Run `python3 scripts/repo_guard.py staged` before local commits. Repository developers should install `git config core.hooksPath .githooks` in their clone.
- The project owner requires express approval before pushes/publishing in their development environment; contributors follow their own repository access policies while respecting release gates.
- Clearly attribute imported upstream source and preserve license notices.
