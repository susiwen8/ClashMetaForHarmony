# Third-Party Notices

The HarmonyOS native rewrite links third-party Go code into
`libcmfa_mihomo.so`. This notice records the direct upstream core dependency;
the complete Go dependency graph and checksums are pinned in
`harmony/core/go/go.mod` and `harmony/core/go/go.sum`.

## mihomo

- Project: MetaCubeX/mihomo
- Module: `github.com/metacubex/mihomo`
- Version: `v1.19.29`
- Source commit: `e26714a181ac0e2fa803453c0a8e9a9ce94e31cb`
- Source: <https://github.com/MetaCubeX/mihomo>
- Tag: <https://github.com/MetaCubeX/mihomo/tree/v1.19.29>
- License: GNU General Public License version 3 (GPL-3.0)

The exact upstream identity is locked in
`harmony/core/go/upstream.lock.json`; the module archive and module-file
checksums are locked in `harmony/core/go/go.sum`. The project repository's root
`LICENSE` contains the GPL version 3 text, and the pinned upstream source ships
the same license text in its `LICENSE` file.

HarmonyOS-specific adapter and C ABI sources are maintained in this repository.
Anyone conveying a build that contains the linked mihomo object code must also
meet the applicable GPL source, license, notice, and installation-information
obligations. Preserve the exact source commit and reproducible build
instructions in the corresponding release materials.

## Transitive Go dependencies

mihomo depends on additional third-party Go modules under their respective
licenses. Before distributing a HAP, review the exact locked dependency set in
`harmony/core/go/go.mod` and `harmony/core/go/go.sum`, retain all required
copyright/license notices, and provide corresponding source where the relevant
license requires it. Generated module caches are build inputs and are not
committed to this repository.

This file is an engineering notice, not legal advice.
