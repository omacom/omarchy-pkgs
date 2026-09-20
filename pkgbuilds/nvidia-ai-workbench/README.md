# NVIDIA AI Workbench on Arch Linux ARM

The vendor desktop and backend binaries are taken from the SHA512-pinned Spark
Debian package. Arch package release 2 removes group/world write permission from
the vendor payload. Release 4 adds native backend provisioning and scoped
compatibility helpers; it does not install an Ubuntu host or VM. Release 6
reorders the setup helper so that every check precedes any change and removes
its global `daemon-reload`. Release 7 makes the service wait for connectivity
with `nm-online` before starting: Omarchy masks NetworkManager-wait-online, so
`network-online.target` no longer means a resolver exists, and a backend started
before DHCP kept a localhost resolver for its whole life, which surfaced in the
desktop app as a compatibility error once the catalog and NGC were unreachable.
Release 8 gives the desktop app its own compatibility view: on Linux it runs
`cat /etc/*-release` and stops at "Cannot install on your operating system"
unless it finds `DISTRIB_ID=Ubuntu` with a supported `DISTRIB_RELEASE`, before
it ever contacts the backend. `/usr/bin/nvidia-ai-workbench` is now a launcher
that binds a compatibility file over `/etc/os-release` for the app's process
tree only, through bubblewrap, and the desktop entry uses it. The host file is
untouched. Inside that view the app reports the OS supported and Workbench
installed, and proceeds to its normal windows. It still tries to take ownership
of the helper binaries in `~/.nvwb/bin`, which are root-owned behind this package's
links; that fails harmlessly and is logged as an unhandled rejection.
Release 9 closes the two update paths a user could click into. The vendor
self-updater's feed (`resources/app-update.yml`) is replaced in the app's view
by one that points at nothing, so the app never offers to download a .deb and
run apt through pkexec; and `~/.nvwb/bin` is mounted read-only for the app,
so its install/repair pass cannot replace the helper links with vendor
binaries. Update the desktop app and its bundled service by updating this
package with pacman; a newer upstream release is packaged by bumping the
pinned .deb.

## Why the adapters exist

The vendor backend classifies Arch as unsupported. In that branch it skips GPU
and NVIDIA Container Toolkit detection and attempts Docker Desktop startup.
The vendor CLI also cannot manage background processes for that OS identifier.

The system service `nvwb-spark@<username>.service` runs the original backend as
that user. A private mount namespace supplies Ubuntu 24.04 metadata **only to
this service** so the existing Linux detection branch runs. A private PATH entry
translates the observed read-only `dpkg-query -Wf` request for
`nvidia-container-toolkit` into `pacman -Q`. Unrecognized package/query requests
fail. No apt implementation is installed, and this package does not change the
host's actual os-release file. The service uses the native Arch libraries,
driver and Docker. Firmware and host package installation remain outside this
adapter.

The CLI adapter handles readiness and shutdown only for the `local` context at
the user's default `~/.nvwb` directory. It checks the actual loopback API and
manages the corresponding system service. Other contexts and operations go to
the original vendor binary.

The helper `wb-svc` uses the real Docker Engine readiness check when the selected
runtime is Docker, and otherwise delegates to NVIDIA. The desktop's integrated
installer/updater still assumes Ubuntu; update this port through pacman.

## Privileges and service model

The package grants no privileges at installation. On first launch, an interactive terminal explains Docker access and asks for confirmation and administrator authentication. The root-owned authorization helper adds only the invoking account to the docker group and installs a sudo rule for enabling, starting and stopping that account's Workbench service. It refuses root accounts, unexpected arguments, invalid usernames and nonstandard home paths. The service and helpers rely on exactly the following:

- `nvwb-spark@<username>.service` runs as that user (`User=%i`) with `HOME` and
  its working directory under `/home/<username>`; the template requires a home
  at that path.
- The account must be in the `docker` group. Docker Engine access is equivalent
  to root on the host, and the service adds no isolation around it.
- The helpers invoke `sudo -n /usr/bin/systemctl` for this one unit with three
  verbs: `enable` and `start` from `nvwb-spark-setup`, `start` from the CLI
  adapter's readiness path and `stop` from its shutdown path. Setup does not run
  `daemon-reload`; pacman's systemd hook reloads the manager whenever the unit
  file is installed or upgraded.
- The backend listens on the fixed loopback port 10001, and the readiness check
  expects the answering backend to report the same username. Only one backend
  can run per host, so this is a single-user arrangement, not a multi-user
  service, and no such promise is made.
- Inside its private mount namespace the service sees the packaged Ubuntu
  metadata at `/etc/os-release` and the `dpkg-query`/`nvidia-smi` adapters
  first in `PATH`. Its descendants inherit that view. The host keeps its own
  `/etc/os-release`; note that `omarchy-settings` separately installs Omarchy's
  identity there.

A sudoers rule sufficient for one account, for the administrator to install
under `/etc/sudoers.d/` with mode 0440:

```
<username> ALL=(root) NOPASSWD: /usr/bin/systemctl enable nvwb-spark@<username>.service, \
    /usr/bin/systemctl start nvwb-spark@<username>.service, \
    /usr/bin/systemctl stop nvwb-spark@<username>.service
```

Release 15 installs this scoped rule through `/usr/lib/nvwb-spark/authorize` after the first-launch confirmation. It never enables unrestricted passwordless sudo. To revoke it, stop/disable the service as an administrator, remove `/etc/sudoers.d/nvwb-spark-<username>`, and remove the account from the docker group. Restart the session to discard its existing group membership.

## Configure

Required native components include Docker, NVIDIA Container Toolkit, git,
git-lfs, pciutils, sudo, Python and PyYAML. The service template currently requires
a home at `/home/<username>`. The Spark ISO registers the NVIDIA Docker runtime. Launch AI Workbench from the application menu to complete account setup. The new process picks up Docker membership without rebooting the desktop. To repeat the user configuration after account authorization, run:

```sh
nvwb-spark-setup
```

Run as the user. The helper validates first and writes nothing until every
check passes: it refuses root, requires the `/home/<username>` home, rejects a
non-Docker runtime in an existing `config.yaml`, requires docker-group
membership and a responding Docker Engine, and lists the existing Workbench
contexts through the packaged CLI. A `local` context that points at another
host or directory stops the helper before any change. Only then are the
existing config, binaries/links and shell files copied to
`~/.nvwb/spark-backups/<timestamp>`, the config rewritten atomically with mode
0600, the links installed, the local context created when absent, the vendor
shell hook installed, and the user's system service enabled and started.
`--no-start` enables the service without starting it.

For an existing shell:

```sh
source ~/.local/share/nvwb/nvwb-wrapper.sh
nvwb activate local
nvwb -c local list projects
```

During transition from experimental release 3, stop and disable the previous
`systemctl --user` unit before starting the new system service. No project should
be building during that transition.

## Validation and limits

The CLI can list the environment catalog, create a project and build NVIDIA's
ARM64 CUDA 13.0 base. A project with one GPU starts JupyterLab, answers HTTP 200
to a request carrying the server token, and executes the CUDA unified-memory
smoke test. All three checks pass after a CLI-managed backend restart. The
private compatibility probe detects GB10, driver 610.57.04, toolkit 1.20.0 and
the configured NVIDIA Docker runtime. Evidence is recorded in
[the hardware report](../../docs/HARDWARE-VALIDATION.md).

That notebook check was a page-level probe. `tests/check-jupyter-runtime.py`
now requires authenticated contents and status API responses without following
redirects, and fails unless requests with no token and with a wrong token are
refused. It passed inside the running project container on the test Spark,
before and after a backend restart. Release 6's setup helper was re-run there
against the existing configuration and changed nothing.

Release 5 normalizes only the legacy CUDA/driver scalar version fields from
`nvidia-smi -q --display=COMPUTE`: NVIDIA 610 appends deprecation notes that the
older Workbench version parser mistakes for part of the number. Actual version
values and other commands are preserved. The adapter exists only in the
service's private PATH.

The supplied tests check readiness failures, delegation of other contexts and
custom workbench directories, truthful/read-only package-query behavior, and
that setup validates before it changes anything and manages only its own unit.
Desktop integration, third-party authentication, remote locations and automatic
vendor updates still require separate validation.

## Recovering an interrupted setup

Setup rejects malformed nested configuration, directory collisions, and pending
helper links before changing files. Before vendor commands run, it backs up
`config.yaml`, `contexts.json`, existing helper links, and shell startup files
under `~/.nvwb/spark-backups/<timestamp>` and prints that location to stderr.
Original symlinks are preserved.

Setup is not a transaction across the vendor CLI and systemd. If a later command
fails, inspect its error and the printed backup before retrying. Restore config
and contexts to `~/.nvwb/`, helper links to `~/.nvwb/bin/`, and shell startup
files to the home directory using `cp -a` to preserve symlinks. Restore only the
files that existed in that backup and inspect newly created state separately.
A service enable/start failure can usually be retried after fixing the scoped
sudo authorization; no global sudo policy is installed.

The packaged desktop skips its vendor ownership/mode adjustment pass when launched
with the package-managed flag. Pacman owns the helper modes; the read-only helper
mount remains enforced. The pinned ASAR patch rejects changed vendor helper code
instead of silently applying to another version.

Desktop host probes use the service's private OS view and package-query PATH.
The native installation is reported complete only when the measured Git/LFS,
Docker, GPU/runtime/toolkit and driver capabilities are ready and the native
service is active. Missing prerequisites keep reconciliation pending; this package
does not claim that the Debian installer itself ran.

Release 16 initializes an empty project inventory on new accounts. Existing inventory is validated and preserved, and included in setup backups. A clean-account hardware test exposed that the vendor backend reads this file without creating it.
