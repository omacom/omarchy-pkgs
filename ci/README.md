# The x86_64 builder pool

x86_64 package builds run on DigitalOcean droplets that exist for one job
each. aarch64 builds run on GitHub's `ubuntu-24.04-arm` runners and need
nothing here.

## How it works

- **Jobs ask for a runner labelled `omarchy-builder`.** `build-pr.yml` builds
  x86_64 packages there, and so does the `rebuild` job in `publish.yml`.
- **A controller creates one droplet per queued job.** `controller.sh` runs
  from a systemd timer every minute on a small always-on droplet (tag
  `omarchy-controller`). It polls GitHub for queued jobs with the label and
  creates droplets up to `MAX_DROPLETS`. It has no inbound endpoint.
- **A droplet runs one job and powers off.** `runner-cloud-init.yaml` installs
  Docker and the GitHub runner, registers it `--ephemeral` with a
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

Only x86_64 jobs use this pool. A queued aarch64 job is waiting on GitHub's
own runners.

### Change settings

Edit `/etc/omarchy-controller.env` on the box. The next tick reads it.

| Setting | Default in `controller-box/controller.env.example` | |
|---|---|---|
| `MAX_DROPLETS` | 6 | Builders alive at once. The DigitalOcean account's droplet limit also applies |
| `SIZES` | `g5-32vcpu-64gb-50gb g5-32vcpu-128gb-50gb` | Tried in order |
| `REGIONS` | empty | Regions to try first; empty means any |
| `MAX_AGE_MINUTES` | 200 | Delete a droplet older than this |
| `MAX_BOOT_MINUTES` | 10 | Delete a droplet still provisioning after this |
| `DO_SSH_KEYS` | Ryan, DHH and Emir's account key IDs | Attached to every builder. Without one, DigitalOcean emails a root password per builder |

### Change the controller

Merge the change to `master`. The unit pulls `/opt/omarchy-pkgs` before every
tick, so it is live within a minute. The unit and timer files are copies made
when the box was created; after changing them, on the box:

```bash
cp /opt/omarchy-pkgs/ci/controller-box/omarchy-controller.{service,timer} /etc/systemd/system/
systemctl daemon-reload
```

`tests/controller.sh` exercises every controller decision against canned API
responses. Run it before merging a change.

### Reach a builder

Operators can SSH to a builder as root while it lives. It powers off after its
one job.

### Clean up by hand

The controller reaps on its own. To do it manually, delete droplets tagged
`omarchy-builder` in the DigitalOcean account.

## Stand up a controller

```bash
DIGITALOCEAN_TOKEN=<account that pays for builders> GITHUB_TOKEN=<fine-grained PAT> \
  REPO=omacom/omarchy-pkgs ci/controller-box/create.sh
```

- The GitHub PAT is fine-grained and scoped to this repository: Actions read,
  Administration read and write (for runner registration tokens).
- The DigitalOcean token is written into the box's env file, so it is the
  account that pays. It needs ssh_key:read to attach `DO_SSH_KEYS`; without
  it every create is refused with 403.
- `ADMIN_GITHUB_USERS` names whose GitHub SSH keys get root on the box and
  the builders. Set it; the default is a fixed list in `create.sh`.
- The script refuses to create a second controller.
