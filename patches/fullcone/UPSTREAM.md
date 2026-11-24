# FullCone NAT integration

This directory vendors the required patch set from
[mufeng05/openwrt-sonic-fullcone](https://github.com/mufeng05/openwrt-sonic-fullcone)
at the immutable upstream commit:

`f87ac2a95b77270af9180a16590cc548617336a1`

The selected integration targets this repository's OpenWrt 25.12.6 / Linux 6.12
baseline and uses firewall4 + nftables only.

Included components:
- Kernel conntrack FullCone support and fixes (patches 984, 986, 987).
- libnftnl expression serialization.
- nftables CLI and JSON/optimizer support.
- firewall4 per-zone/per-protocol rule generation.
- Native LuCI firewall controls and Simplified Chinese translations.

The iptables/fw3 patches are intentionally omitted because this firmware uses
firewall4. This SONiC implementation extends the existing NAT modules; it does
not require a standalone `kmod-nft-fullcone` package.

Upstream documentation: `README.en.md` in the pinned repository.
