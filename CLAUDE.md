# claude-box — project instructions

`claude-box` builds and runs the **Claude Code CLI sandbox image** (Debian base +
`gh` + the `gh-stack` extension + gitleaks + Vite+/Node + pnpm + Claude Code), run
under Apple `container`. The image is defined in `Dockerfile` and launched by the
`claude-box` runner script; see `README.md` for usage.

## Git workflow — commit directly to the default branch

**This repo commits directly to `main` and pushes — NO feature branches, NO pull
requests.** It is personal infrastructure co-edited with the user; a PR/review flow
adds overhead with no benefit here. **Do not open PRs against this repo.** Just
stage, commit to `main`, and push.

## After changing the image

`Dockerfile` changes take effect only after a rebuild — `./claude-box build` on the
host. Committing alone does not update a running sandbox.
