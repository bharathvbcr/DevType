# Website maintenance

[Documentation](README.md)

## Ownership

`docs/index.html` is the DevType landing page. Its styles and demo behavior live in `docs/assets/site.css` and `docs/assets/site.js`. Existing screenshots and branding stay under `docs/assets/`. There is no npm project, framework, dependency download, or compilation step.

The snippet playground is an illustrative browser interaction with three fixed examples. It does not implement the native template engine and does not read the clipboard, request permissions, save text, or send it to a server. Features and documentation links remain usable without JavaScript. Native screenshots are labeled separately from the demo.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs
```

Open [the local preview](http://127.0.0.1:8765). Stop the server with Control-C when finished.

Check desktop and narrow mobile widths, browser zoom, keyboard focus, anchor navigation, and FAQ disclosure controls. Try all three sample buttons, manually type the triggers, reset, and edit text in the middle of the note. Confirm that IME composition is not expanded mid-composition and that deletion does not trigger expansion. Check browser errors and failed asset requests. With JavaScript disabled, the page should still expose the product, setup, documentation, and download links. Reduce Motion should disable smooth scrolling and hover motion.

## Page content

The landing page covers the snippet demo, feature overview, everyday template workflows, native library and palette screenshots, writing actions and output choices, voice engines, customization, privacy, text-delivery behavior, independent Secrets, library import/export, troubleshooting, installation, documentation, and FAQs. Jump links connect the longer product sections. Keep examples aligned with the macro reference and voice guide.

## Content conventions

- Follow `Sources/DevTypeAppCore/DevTypeTheme.swift`: Crimson Glass accents, warm surfaces, system typography, and 22/14/9 px panel/card/control radii. CSS tokens adapt to system light/dark appearance and increased contrast; web sRGB colors approximate the app’s calibrated palette.
- Use the existing system font stack and local assets; no remote font or analytics dependency.
- Document platform and model readiness separately. Avoid latency or accuracy claims without a reproducible measurement.
- Link downloads to GitHub Releases rather than a guessed artifact filename or hardcoded current version.
- Keep current user instructions in the guides; retain dates and scope on audits and release notes.
- Compare privacy copy with the implemented data routes, including setup downloads, local services, saved recordings, and opt-in cloud features.

## Hosting and publication

The intended canonical URL is `https://devtype.vbcr.dev/`, used in metadata and social cards. The complete `docs/` directory is the static public root; asset paths are relative so a local preview also works under a subpath.

**Observed on 2026-09-13 (America/Chicago):** an HTTPS request to that hostname returned a portfolio page, not this DevType landing page. The repository's GitHub Pages API returned HTTP 404. No hosting configuration or website deployment workflow is checked into this repo. These observations do not establish which hosting project owns the hostname.

Before publication, identify the hosting project that owns this domain, serve the DevType public root there, and verify the rendered page, asset responses, canonical URL, TLS, and download links at the public hostname. Avoid changing a shared portfolio site's public root to resolve the hostname mismatch. A local preview, repository push, or successful app release does not prove this website is deployed.
