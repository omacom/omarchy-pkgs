# The x86_64 builder pool

x86_64 package builds run on DigitalOcean droplets that exist for one job
each. aarch64 builds run on GitHub's `ubuntu-24.04-arm` runners, and aarch64
kernels on Namespace's Apple-backed runners (`package_runner` in
`helpers/package-metadata.sh`); neither needs anything here. Chromium is the
exception: its aarch64 build cross-compiles on a droplet too
(`package_build_host`).

## How it works

- **Jobs ask for a runner labelled `omarchy-builder`.** `build-pr.yml` builds
  x86_64 packages there, and so does the `rebuild` job in `publish.yml`.
  `chromium*` asks for `omarchy-builder-large` instead (`package_runner`), and
  gets a droplet of `LARGE_SIZES`: 64 vCPU and 128 GB, because its build was
  killed for memory on a 64 GB builder. Chromium's aarch64 build asks for the
  same pool and cross-compiles there. Each label is its own pool with its
  own cap: a large droplet never takes an ordinary job, and the reverse.
- **A controller creates one droplet per queued job.** `controller.sh` runs
  from a systemd timer every minute on a small always-on droplet (tag
  `omarchy-controller`). It polls GitHub for queued jobs with the label and
  creates droplets up to `MAX_DROPLETS`. It has no inbound endpoint.
- **A droplet runs one job and powers off.** `runner-cloud-init.yaml` installs
  Docker and the GitHub runner (verifying its pinned `linux-x64` tarball
  SHA-256 before extracting; obsolete `RUNNER_VERSION`, `RUNNER_SHA256`, and
  `CLOUD_INIT` env overrides are ignored with a warning in favor of the
  bundled template), registers it `--ephemeral` with a
  registration token that expires in an hour, runs the job, and powers off, also when the runner download or
  registration fails. The controller removes any other failed droplet at
  `MAX_AGE_MINUTES`.
- **The controller deletes droplets** that are powered off, older than
  `MAX_AGE_MINUTES`, or still provisioning after `MAX_BOOT_MINUTES`, and
  replaces a stuck one in the same tick.
- **Sizes and regions fall back.** Each tick tries every size in `SIZES`, in
  every region DigitalOcean lists it in stock. `REGIONS` only sets which
  regions go first. A refused create is logged with DigitalOcean's message.

No secret reaches a builder. Signing and upload happen in the `publish` job on
a GitHub-hosted runner.

## Operate it

SSH to the controller droplet as root. It is the droplet tagged
`omarchy-controller` in the DigitalOcean account that pays for the builders;
the operators' keys were installed when it was created.

```bash
journalctl -u omarchy-controller -n 50 --no-pager   # What it is doing
journalctl -u omarchy-controller -f                 # Follow it
systemctl list-timers omarchy-controller.timer      # Is it ticking
```

| Log line | Meaning |
|---|---|
| `creating <name> (<size> in <region>)` | A queued job is getting a droplet |
| `<size> in <region> refused: <message>` | DigitalOcean refused; the next region or size is tried |
| `no size in '<sizes>' can be created in any region` | Every create was refused. Read the `refused:` lines above it for why: out of stock (add a size to `SIZES`), or the account's droplet limit |
| `at cap (<live>/<max>, <busy> busy) with <queued> queued` | `MAX_DROPLETS` is reached. Raise it if the queue is long |
| `deleting droplet <id> (status=<status> age=<n>m)` | Reaping a finished, old or stuck droplet |

Check the pool from anywhere:

```bash
gh api repos/omacom/omarchy-pkgs/actions/runners --jq \
  '"online \([.runners[]|select(.status=="online")]|length), busy \([.runners[]|select(.busy)]|length)"'
```

Jobs queued with no runner online for several minutes means the controller is
not creating droplets: read its journal. See what is waiting:

```bash
gh run list -R omacom/omarchy-pkgs --workflow build-pr.yml --status queued
```

Only x86_64 jobs use this pool, plus chromium's aarch64 build, which
cross-compiles on the large droplets. Any other queued aarch64 job is
waiting on GitHub's or Namespace's runners.

### Change settings

Edit `/etc/omarchy-controller.env` on the box. The next tick reads it.

| Setting | Default in `controller-box/controller.env.example` | |
|---|---|---|
| `MAX_DROPLETS` | 6 | Ordinary builders alive at once. The DigitalOcean account's droplet limit also applies |
| `SIZES` | `g5-32vcpu-64gb-50gb g5-32vcpu-128gb-50gb` | Tried in order |
| `LARGE_SIZES` | `g5-64vcpu-128gb-80gb` | Sizes for jobs labelled `omarchy-builder-large`, tried in order |
| `MAX_LARGE_DROPLETS` | 1 | Large builders alive at once, apart from `MAX_DROPLETS` |
| `REGIONS` | empty | Regions to try first; empty means any |
| `MAX_AGE_MINUTES` | 265 | Delete a droplet older than this. Must exceed the longest builder job `timeout-minutes` plus `MAX_BOOT_MINUTES` and teardown headroom; on existing controller boxes seeded with `200` in `/etc/omarchy-controller.env`, raise it to `265` first or remove the line after the controller pulls the new default |
| `MAX_BOOT_MINUTES` | 10 | Delete a droplet still provisioning after this |
| `DO_SSH_KEYS` | Ryan, DHH and Emir's account key IDs (overridden when `DO_SSH_KEYS` is passed to `create.sh`) | Attached to every builder. Without one, DigitalOcean emails a root password per builder |

### Change the controller

Merge the change to `master`. The unit pulls `/opt/omarchy-pkgs` before every
tick, so it is live within a minute. The unit and timer files are copies made
when the box was created; after changing them, on the box:

```bash
cp /opt/omarchy-pkgs/ci/controller-box/omarchy-{controller.service,controller.timer,dispatch@.service,dispatch-*.timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now omarchy-dispatch-{sync-hourly,sync-six-hourly,sync-rebuilds,builder-images}.timer
```

`tests/controller.sh` exercises every controller decision against canned API
responses. Run it before merging a change.

### Scheduled workflows

The box also keeps the repo's clock. GitHub's `on: schedule` started these
workflows 3 to 7 hours late and fired an hourly one about once every four
hours, so they have no cron. A systemd timer per schedule runs
`ci/dispatch.sh <name>`, which starts the workflow with `workflow_dispatch`
on `master`.

| Timer | UTC | Starts |
|---|---|---|
| `omarchy-dispatch-sync-hourly` | every hour at :35 | `sync-upstream.yml`, `cadence=hourly` |
| `omarchy-dispatch-sync-six-hourly` | 00:20, 06:20, 12:20, 18:20 | `sync-upstream.yml`, `cadence=six-hourly` |
| `omarchy-dispatch-sync-rebuilds` | every hour at :50 | `sync-rebuilds.yml` |
| `omarchy-dispatch-builder-images` | 04:23 | `builder-images.yml` |

```bash
systemctl list-timers 'omarchy-dispatch-*'                  # Next and last run
journalctl -u 'omarchy-dispatch@*' -n 20 --no-pager         # Recent dispatches
systemctl start omarchy-dispatch@sync-hourly                # Dispatch one now
```

A failed dispatch leaves the unit failed (`systemctl --failed`) with
GitHub's response in its journal. A 403 means `GITHUB_TOKEN` lost Actions
write.

To add or move a schedule, add its name to the `case` in `dispatch.sh` and a
timer to `controller-box/`, then install the timer as below.

### Reach a builder

Operators can SSH to a builder as root while it lives. It powers off after its
one job.

### Clean up by hand

The controller reaps on its own. To do it manually, delete droplets tagged
`omarchy-builder` in the DigitalOcean account.

## Stand up a controller

```bash
DIGITALOCEAN_TOKEN=<account that pays for builders> GITHUB_TOKEN=<fine-grained PAT> \
  DO_SSH_KEYS='[<account ssh key id>]' REPO=omacom/omarchy-pkgs ci/controller-box/create.sh
```

- The GitHub PAT is fine-grained and scoped to this repository: Actions read
  and write (to dispatch the scheduled workflows), Administration read and
  write (for runner registration tokens).
- The DigitalOcean token is written into the box's env file, so it is the
  account that pays. It needs ssh_key:read to attach `DO_SSH_KEYS`; without
  it every create is refused with 403.
- `DO_SSH_KEYS` is required (unless it is unset and `SSH_KEYS` is set) and
  must be a non-empty JSON array of positive integer SSH key IDs or literal
  colon-separated MD5 fingerprints registered with the DigitalOcean account
  (list them with `doctl compute ssh-key list`). By default it attaches to
  both the controller droplet (granting root SSH access) and every builder
  via `/etc/omarchy-controller.env`. To use a separate key list for the
  controller droplet, pass `SSH_KEYS` alongside `DO_SSH_KEYS`; if
  `DO_SSH_KEYS` is unset, `SSH_KEYS` sets only the controller droplet keys
  and keeps the example `DO_SSH_KEYS` defaults in `/etc/omarchy-controller.env`.
  An exported empty `DO_SSH_KEYS=` or `SSH_KEYS=` still counts as set and
  fails validation.
- `ADMIN_GITHUB_USERS` names whose GitHub SSH keys get root on the box and
  the builders. Set it; the default is a fixed list in `create.sh`. Every
  listed user must have at least one GitHub SSH key.
- The script refuses to create a second controller.
