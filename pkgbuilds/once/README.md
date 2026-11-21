# Rootless ONCE package

This source build is based on the checksum-pinned upstream ONCE v0.3.2 archive. It provides `once-bin` for existing menu/package checks and conflicts with that vendor binary package. It does not install or enable an engine, change host sysctls, or enable the legacy system service.

`rootless.patch` contains the integration fixes required by both container proposals:

- `ONCE_ROOTLESS=1` selects loopback HTTP 8080 / HTTPS 8443, validates existing proxy bindings, and configures low ports only inside the private network namespaces of ONCE-created containers.
- Backups normalize Docker's `storage/...` and Podman's `/...` archive entries to the same `data/...` format, including hard links. Restore targets the mounted volume directly instead of the unstarted temporary container's root filesystem. Unexpected paths are rejected, including archives produced by the broken unpatched Podman path.
- Exec results wait for `Running=false` before interpreting the final exit code.

The resulting binary identifies as `v0.3.2-omarchy1`. Omarchy's launcher requires that build and disables binary self-update. The patch and its Go regression tests should be reevaluated against every upstream release; remove downstream changes once upstream supplies the same behavior. This is not a claim that the unmodified vendor binary supports rootless Podman.

`makepkg` builds the binary and runs upstream's internal unit suite plus the regression tests. Real Writebook lifecycle validation belongs in Omarchy Lab; a passing package build alone does not establish engine compatibility. The preserved system unit exists only for explicitly retained legacy deployments. New installations use `omarchy-once.service` in the user manager.
