# Security policy

## Current status

Pre-release: supported versions and a private vulnerability reporting channel are not yet established. Do not post vulnerability exploit details or credentials publicly.

## Responsible disclosure

After the repository is published, configure GitHub's **Private vulnerability reporting** if available and document the verified disclosure entry point here. Until then, use a private channel already established with the maintainer; do not invent or publish a personal email address.

## Technical threat model

Archive path traversal, symlink escape, special files, ZIP bombs, malformed metadata, filename collision and resource exhaustion are in scope for security tests. Normal extraction must not mutate extracted bytes.

The repository must contain **no** actual API keys, tokens, signing private keys, .env files, passwords or other authentication material, including commit history and example files.
