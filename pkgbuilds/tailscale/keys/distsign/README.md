# Tailscale's signing keys

Tailscale signs its downloads with its own format, not PGP. `verify()` in the PKGBUILD checks every tarball against the keys here, the way Tailscale's updater does (`clientupdate/distsign` in tailscale/tailscale). They ship with the recipe so that a build asks no server for a key.

- `roots/`: the root keys, copied from `clientupdate/distsign/roots/` in Tailscale's source. Tailscale changes them only with a release of its client.
- `distsign.pub` and `distsign.pub.sig`: the signing keys, and a root key's signature over them, from `https://pkgs.tailscale.com/`.

## When Tailscale signs with a new key

The build of the next release fails with `No key in keys/distsign/distsign.pub signed ...`, and the update's pull request stays open and red. Fetch the signing keys again and open a pull request with them:

```bash
cd pkgbuilds/tailscale/keys/distsign
curl -fsSLO https://pkgs.tailscale.com/distsign.pub
curl -fsSLO https://pkgs.tailscale.com/distsign.pub.sig
../../../../tests/tailscale-recipe.sh
```

The test and the build accept the new file only if a key in `roots/` signed it. If neither does, compare `roots/` with Tailscale's source at its newest release tag before changing anything.
