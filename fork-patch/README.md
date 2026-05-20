# fork-patch — patched player.py for hardware verification

`player.py` here is the Music Assistant `squeezelite` provider with the
upstream-PR fix applied, **rebased onto the 2.8.7 source tree**. It is intended
to be `docker cp`-ed into the running MA 2.8.7 Docker container by
`../apply-fork-patch.sh` for hardware verification before the upstream PR is
merged.

This file is **derived** from the fork branch
`digodigo/server:fix/squeezelite-sync-honor-per-child-format` by cherry-picking
the fix commit onto the `2.8.7` tag (the cherry-pick applies cleanly — the
URL-construction block is identical between 2.8.7 and current `dev`, modulo
a one-line whitespace shift).

If MA upgrades to a Python version other than 3.13, the `TARGET` path in
`../apply-fork-patch.sh` must be updated to match.
