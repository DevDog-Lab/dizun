# GitHub Pages deployment plan (not active)

- Static landing-page source is `site/index.html`. No remote assets, analytics or JavaScript dependencies.
- Before activation, decide actual project name, public repo slug, branding/logo ownership, LICENSE copyright holder, issue/disclosure policy, and verified feature list.
- GitHub Pages can be configured to publish a dedicated static site. Choose a maintained, reviewed workflow or deploy from an explicit branch/folder after deciding structure. Do not deploy from a branch that contains unintended generated data.
- GitHub Pages is a **remote publication** and requires separate, explicit user approval, even after repository push approval.
- Security defaults: minimal workflow permissions, no repository secrets needed for basic static content; no third-party analytics/remote scripts.
