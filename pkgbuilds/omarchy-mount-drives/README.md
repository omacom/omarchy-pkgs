# Mount Drives

A small command-line tool that mounts the extra drives declared in
`/etc/fstab` under `/run/media/<user>/`, so they appear in your file manager.

File managers only show volumes that are already mounted. This tool reads
fstab on every run, so it picks up new drives without any configuration: any
filesystem mounted under your `/run/media` directory is managed, regardless
of its type. It starts the matching systemd mount unit (so the fstab options
are honoured) and falls back to a plain `mount` when the unit is missing.

## Usage

```
omarchy-mount-drives                 Mount every drive, then show status
omarchy-mount-drives status          Show status only
omarchy-mount-drives list            List the drives this tool manages
omarchy-mount-drives mount [NAME]    Mount one drive (or all)
omarchy-mount-drives unmount [NAME]  Unmount one drive (or all)
omarchy-mount-drives toggle [NAME]   Mount when unmounted, unmount when mounted
omarchy-mount-drives open [NAME]     Open a drive in the file manager
omarchy-mount-drives is-mounted NAME Exit 0 when the drive is mounted
```

`NAME` matches the last part of the mount point (the drive name),
case-insensitively. Add `--no-notify` to suppress desktop notifications.

## Requirements

- `bash`, `coreutils`, `systemd`, `util-linux`, `polkit` and `awk`
- On Omarchy, `omarchy` supplies the desktop launcher and notifications, and
  `uwsm` lets `open` launch Folio in the running session. Elsewhere `open`
  falls back to `xdg-open`.
