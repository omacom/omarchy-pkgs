# NVIDIA AI Workbench on Arch Linux ARM

This package repackages NVIDIA's pinned arm64 Debian release of AI Workbench
for the DGX Spark and adds small adapters so it runs on Arch Linux ARM. It is a
temporary compatibility layer until NVIDIA supports the platform directly.

## Why the adapters exist

The vendor app and backend only accept Ubuntu. On other systems the backend
skips GPU and NVIDIA Container Toolkit detection and tries to start Docker
Desktop, and the desktop app refuses to start. The adapters work around this
without changing the host:

- The backend runs as `nvwb-spark@<username>.service` and the desktop app runs
  through bubblewrap. Each sees Ubuntu metadata at `/etc/os-release` in its own
  mount namespace; the host file is untouched.
- A private `PATH` supplies a `dpkg-query` that answers only the toolkit query
  from `pacman -Q`, and an `nvidia-smi` wrapper that strips driver 610's
  deprecation notes from two version fields. There is no apt.
- The CLI adapter starts and stops the service for the `local` context and
  passes everything else to NVIDIA's CLI.
- The app's self-updater and helper repair pass are disabled. Update Workbench
  with pacman.

## Privileges

Installing the package grants nothing. On first launch a terminal explains the
access needed and asks for confirmation and your password. It then:

- adds your account to the `docker` group, which is equivalent to root access;
- installs `/etc/sudoers.d/nvwb-spark-<username>`, allowing only:

```
<username> ALL=(root) NOPASSWD: /usr/bin/systemctl enable nvwb-spark@<username>.service, \
    /usr/bin/systemctl start nvwb-spark@<username>.service, \
    /usr/bin/systemctl stop nvwb-spark@<username>.service
```

Setup then configures `~/.nvwb`, backing up existing files to
`~/.nvwb/spark-backups/`, and enables and starts the service. To repeat it,
run `nvwb-spark-setup` as your user.

## Revoking access and uninstalling

Removing the package does not undo setup. The sudoers rule, docker group
membership, the enabled service link and the links in `~/.nvwb/bin` stay
behind. To revoke access, run these before removing the package:

```sh
sudo systemctl disable --now nvwb-spark@<username>.service
sudo rm /etc/sudoers.d/nvwb-spark-<username>
sudo gpasswd -d <username> docker
rm ~/.nvwb/bin/{nvwb-cli,wb-svc,credential-manager}
```

Log out and back in to drop the docker group from your session.
`~/.nvwb` also holds your projects and configuration; remove it only if you no
longer need them.

## Limitations

- One user per machine: the backend uses fixed loopback port 10001, and the
  home directory must be `/home/<username>`.
- Remote locations and third-party authentication have not been validated.
- The desktop app's integrated installer still assumes Ubuntu and is not used.
