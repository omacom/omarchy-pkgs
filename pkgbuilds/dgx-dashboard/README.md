# DGX Dashboard on Arch Linux ARM

Experimental package pinned to vendor release 0.25.11. The vendor
DEB URL and SHA256 were obtained from the Spark's APT metadata. Package files
are downloaded directly, with no vendor binaries committed here.

This translates Debian installation actions to Arch sysusers/tmpfiles and
package-owned system units. Service users cannot modify packaged binaries or
service definitions. The runtime notebook port map is service-writable. Service
startup is deliberately left to the eventual system integration step.

The package is not complete functional parity. Notebook provisioning and token
authentication have dedicated native checks below; device settings still require
validation. Ubuntu-specific update transactions remain disabled. Packaging or
binary loading alone does not establish functional support.

Binary paths and the original D-Bus policy are retained. The web service depends
on its admin service, and the vendor ports.env is the single port setting.

## Native Arch status backend (release 2)

The admin service has a private PATH containing adapters for its observed
`apt update`, `apt list --upgradable`, `apt dist-upgrade -s` and
`apt-cache show <candidate>` queries. They refresh a temporary pacman database,
read actual installed versions and repository metadata, and resolve a complete
transaction with pacman's print-only mode. No package is installed and the live
sync database is unchanged. The helpers are not on the host's normal PATH.

Inspect the full, timestamped result with:

```sh
sudo dgx-arch-package-status --refresh
```

The JSON includes held updates, the transaction preview, resolver warnings and
packages outside configured repositories. The latter need a port-managed source;
absence of repository updates is not proof those custom packages are current.
Successful results cache for at most 15 minutes. Refresh failures invalidate the
previous snapshot and return a nonzero status; unsupported operations fail.
The vendor UI can still collapse query errors into an empty package list, so the
JSON command's successful exit and timestamp are authoritative when diagnosing
update status. This remaining UI error-reporting limitation needs a frontend or
service API change, not a fabricated package record.

The vendor `UpdateAndReboot` method combines Ubuntu aptdaemon, firmware and reboot.
The package's D-Bus policy rejects that method until a native transaction and
rollback path is implemented. Firmware inventory remains available, but Dashboard
installation is unavailable; the Updates page replaces its transaction button with terminal instructions
to run `omarchy update`, with firmware handled separately. No firmware has been flashed. This is an explicit incomplete
integration, not an Arch replacement for the full factory updater.

### Validation on 2026-09-06

- Native repository refresh and full transaction preview succeeded with zero
  pending repository updates. Fifteen locally built packages are inventoried.
- SHA256 of all four live sync databases stayed unchanged during the check.
- A separate vendor backend, on a private D-Bus and with a temporary credential
  store, parsed a synthetic update including epoch versions, description and size.
  `tests/check-dashboard-protocol.sh` reproduces that isolated protocol test.
- Production D-Bus inventory returns actual available firmware; the combined
  mutation method is denied before dispatch (tested with an invalid signature).
- Both services remain active, the web endpoint returns 200, and package integrity
  reports 51 files with zero changes. No failed system services.
- Unit tests cover query failures, version/held-package parsing, rejected writes,
  cache reuse and invalidation on refresh failure.

Native adapters follow the separate-database strategy described by
[checkupdates](https://man.archlinux.org/man/checkupdates.8.en), and the
[pacman print mode](https://man.archlinux.org/man/pacman.8.en) for transaction previews.

## Notebook runtime — 2026-09-07


The vendor notebook installer pins a Python scientific stack that cannot be
installed reliably with Arch's system Python 3.14. On the Spark, the installation
failed building SciPy/scikit-learn; installing a Fortran compiler alone would not
resolve the pinned stack's Python compatibility.

Release 6 provisions Python 3.12.14 automatically on first notebook launch.
The admin service's private `python3` helper intercepts creation of
`~/jupyterlab/.venv` and uses the packaged `uv` dependency to download a managed
interpreter and create a seeded environment as the desktop user. Dashboard then
installs its vendor requirements and launches Jupyter normally. Other Python
commands still use the system interpreter.

Existing environments and notebooks are preserved; the helper refuses to replace
an existing `.venv`, including a dangling symlink. An environment left by an older
failed installation still needs individual diagnosis and backup before repair.
First launch requires internet access and downloads several GiB of Python/CUDA
wheels. The managed interpreter and these wheels are outside pacman's inventory.

On 2026-09-07 this environment started through Dashboard and passed authenticated
contents, status and Lab requests, rejecting absent/wrong tokens with HTTP 403.
A PyTorch GPU arithmetic check passed. Two vendor-wheel limitations remain:
PyTorch 2.9.0 warns about GB10 compute 12.1 support, and `pip check` reports the
vendor cusparselt wheel's `manylinux2014_sbsa` platform tag as unsupported. The
successful arithmetic check is not certification of every CUDA operation.

## Updates page (release 5)

The package patches the pinned embedded web bundle at build time. Update rows
remain visible, but the Update confirmation/transaction component is replaced
with `omarchy update` terminal guidance in loaded, empty, and loading states.
The frontend no longer dispatches the Ubuntu update/reboot operation from that
component; the existing D-Bus denial remains in place. The patch requires exact
vendor byte sequences and preserves the executable's embedded asset offsets.

### Reproducing first-launch validation

`tests/check-dashboard-notebook.sh` is an opt-in integration check for a disposable
native ARM builder container, with its existing `builder` user (UID 1000) and a
clean home. Mount this checkout at `/source`, the package directory at `/package`,
a writable evidence directory at `/proof`, and the builder's package repository
at `/repo`. Run as container root:

```sh
bash /source/tests/check-dashboard-notebook.sh /package/dgx-dashboard-0.25.11-6-aarch64.pkg.tar.xz
```

It installs the package and dependencies inside the container, starts the actual
admin binary on a private D-Bus, and invokes notebook activation. It checks the
Python version, notebook preservation, repeat activation, and authenticated and
unauthenticated HTTP access. Allow up to 30 minutes for downloads. Do not mount a
real user home or the host system bus. `/proof/admin.log` can contain notebook
tokens; keep it private. `result.json` contains only token-free validation results.
