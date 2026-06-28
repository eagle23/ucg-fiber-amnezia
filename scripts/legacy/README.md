# Legacy: bind-mount wg-shim path (deprecated)

These scripts implement the **old** integration: a `wg-shim` bind-mounted over
`/usr/bin/wg` that intercepted `wg syncconf/setconf`, recreated `wgcltN` as an
`amneziawg`-type interface, merged dumps and repaired PBR.

They are **superseded** by the amnezia-as-wireguard design (module registered as
`wireguard` + kernel-side `iface_junk` injection — see the top-level README) and
are kept only for reference / rollback. Do not mix the two: the new design owns
the `wireguard` module and does not intercept `wg`.

- `wg-shim`, `install-wg-shim.sh`, `uninstall-wg-shim.sh`,
  `restore-managed-iface.sh` — the shim and its install/rollback.
- `amneziawg.rc.local`, `amneziawg.service` — old boot paths (insmod
  `amneziawg.ko` + manual `awg-quick`).
