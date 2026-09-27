# CI spike: build PRs on ephemeral DigitalOcean droplets

Status: spike. Nothing here publishes. The repository host keeps building and
signing on merge exactly as before.

## Pieces

- `.github/workflows/build-pr.yml` — on a PR touching `pkgbuilds/**`, one job
  per changed package on runners labelled `omarchy-builder`. Uploads the
  unsigned `.pkg.tar.zst` as a workflow artifact (7 days).
- `runner-cloud-init.yaml` — Ubuntu 24.04 user-data: docker + buildx, the
  GitHub runner registered `--ephemeral`, runs one job, powers off.
- `controller.sh` — systemd timer every minute on a small always-on droplet.
  Polls for queued jobs with our label, creates one g5-32vcpu-64gb-50gb droplet (ric1) per job up
  to `MAX_DROPLETS`, deletes droplets that are powered off or older than
  `MAX_AGE_MINUTES`. No inbound endpoint. Plain curl against both APIs, no
  doctl and no gh: a token in the environment cannot pick the wrong account
  the way a saved doctl context can. Needs curl and jq.
  `tests/controller.sh` exercises every decision against canned responses.
- `controller-box/` — the always-on droplet: unit, timer, env template,
  cloud-init, and `create.sh` to stand it up with one API call.

## Standing up the controller box

    DIGITALOCEAN_TOKEN=<omarchy account> GITHUB_TOKEN=<fine-grained PAT> \
      REPO=omacom/omarchy-pkgs ci/controller-box/create.sh <branch>

The GitHub PAT is fine-grained, scoped to the one repo: Actions read,
Administration read+write (registration tokens). The DO token is baked into
the box's env file, so it is the account that pays for builder droplets.
Watch it with `journalctl -u omarchy-controller -f` on the box.

## What the spike proved (2026-09-17, fork ryanrhughes/omarchy-pkgs)

- `bin/build` works from a bare clone: with no local published tree it
  plans against and resolves from `https://pkgs.omarchy.org/<mirror>/<arch>`.
- Droplet create → runner registered: ~70 s. omarchy-fish PR job: 2 min
  including the builder image build. Droplet powers off after the job.
- linux-omarchy on a c-32 droplet: 30 min wall clock for the build job
  (23:39 → 00:09), 254 MB artifact. Cold start ~90 s before the job began.
- A PR whose PKGBUILD fails to build turns the required check red and GitHub
  refuses the merge (`mergeStateStatus=BLOCKED`, `gh pr merge` refuses
  without `--admin`).
- Controller: one queued job + one busy droplet ⇒ creates exactly one more;
  reaps powered-off droplets on the next tick.

## Not done (required before this touches the real repo)

- Tooling from base: check out master's `bin/ helpers/ build/` and overlay
  only the PR's `pkgbuilds/<name>`; today a PR can edit the build script
  and it runs on the droplet. The vouch gate limits who can do that, not
  what they can do.
- DigitalOcean cloud firewall on the `omarchy-builder` tag: no inbound, no
  egress to private ranges or the metadata address.
- A fine-grained GitHub token for the real repository (the one on the
  controller box is scoped to the fork), and the publish environment's
  secrets set there.
- Disable the host's auto-release timers for any channel CI publishes to,
  so two writers never touch one database.

## Done since the spike README was first written

- Controller as a systemd timer on its own droplet, plain curl, self-test.
- Build once against edge; one artifact per package per architecture,
  published into every channel it belongs to (fast ring: all three at
  once). arch=any builds once for every architecture database.
- Publish is incremental and immutable: pull the channel db, refuse
  different bytes under an existing name, accept identical bytes, upload
  packages then signatures then the db.
- aarch64 under QEMU with credential-preserving binfmt.
- The binfmt image is pinned by reviewed digest in both the Docker helper and cloud-init; update both references together. Run privileged registration on disposable builders without reusable credentials.
- Vouch gate: collaborators, `.github/VOUCHED.td`, or the `build-approved`
  label; denounced authors cannot be overridden by the label.
- Tests run on PRs only; `result`, `self-tests`, `build-isolation` are the
  required checks with strict up-to-date branches.

## Cleanup

    doctl compute droplet list --tag-name omarchy-builder
    doctl compute droplet delete -f <id>
