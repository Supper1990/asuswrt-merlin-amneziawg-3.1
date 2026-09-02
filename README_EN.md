# AmneziaWG for Asuswrt-Merlin

[[Русский]](README.md) · [[English]](README_EN.md)

**AmneziaWG** client with a web interface for ASUS routers running **Asuswrt-Merlin**.

The project provides a userspace implementation of AmneziaWG with configuration import, per-device routing, GeoIP/GeoSite support, and custom rules.

## Features

- **AmneziaWG 2.x and 3.1** — support for current AmneziaWG configurations
- **Userspace implementation** — based on `amneziawg-go`, with no separate kernel module required
- **Web interface** — manage AmneziaWG directly from the Asuswrt-Merlin interface
- **Configuration import** — upload an existing `.conf` file
- **Per-device routing** — individual rules for local network devices
- **Full routing** — route all traffic from a selected device through AmneziaWG
- **Selective routing** — route only selected traffic through AmneziaWG
- **Direct connection** — exclude a device from routing through AmneziaWG
- **GeoIP** — routing by IP addresses and CIDR networks
- **GeoSite** — routing by domain lists
- **Custom Domains** — custom domain rules
- **Custom IPs** — custom IP addresses and CIDR networks
- **DNS routing** — integration with `dnsmasq` and `ipset`
- **MSS clamping**
- **GeoIP/GeoSite list updates**
- **Automatic AmneziaWG update checks**
- **Install updates from the web interface**
- **Preserve user settings and configuration during normal updates**

## Requirements

- compatible ASUS router
- Asuswrt-Merlin firmware
- Entware installed
- SSH access to the router
- an AmneziaWG configuration

## Installation

Download the appropriate `.ipk` package from **Releases**.

Use the package matching your router architecture.

### 1. Copy the package to the router

```sh
scp amneziawg_*.ipk admin@<ROUTER-IP>:/tmp/
```

### 2. Connect to the router via SSH

```sh
ssh admin@<ROUTER-IP>
```

### 3. Install the package

```sh
opkg install /tmp/amneziawg_*.ipk
```

### 4. Open the web interface

After installation:

1. Log out of the Asuswrt-Merlin web interface and log back in.
2. Open the **AmneziaWG** page.
3. Import your `.conf` configuration.
4. Check the imported parameters.
5. Click **Apply**.
6. Start AmneziaWG.
7. Configure routing rules for devices if needed.

## Routing

Each local network device can use its own routing mode.

### All traffic

All traffic from the selected device is routed through AmneziaWG.

### Selective routing

Only traffic matching selected GeoIP, GeoSite, and custom rules is routed through AmneziaWG.

### Direct connection

Traffic from the selected device is routed directly.

## GeoIP

GeoIP provides routing by IP addresses and CIDR networks.

You can use predefined lists and add your own addresses and networks through **Custom IPs**.

Example:

```text
8.8.8.8
1.1.1.0/24
```

## GeoSite

GeoSite provides routing by domain lists.

Domain rules are processed using integration with `dnsmasq` and `ipset`.

For domain routing to work correctly, client devices must use the router as their DNS server.

## Custom Domains

Use **Custom Domains** to add your own domain names.

Example:

```text
example.com
example.org
```

## Custom IPs

Use **Custom IPs** to add individual IP addresses or CIDR networks.

Example:

```text
8.8.8.8
1.1.1.0/24
```

## Updates

AmneziaWG automatically checks for new versions.

When an update is available, information about it is displayed in the web interface.

Updates can be installed directly from the AmneziaWG web interface.

User settings and configuration are preserved during normal updates.

## SSH Management

### Start

```sh
/opt/etc/init.d/S99amneziawg start
```

### Stop

```sh
/opt/etc/init.d/S99amneziawg stop
```

### Restart

```sh
/opt/etc/init.d/S99amneziawg restart
```

### AmneziaWG status

```sh
awg show
```

## Uninstallation

To remove AmneziaWG:

```sh
/jffs/addons/amneziawg/amneziawg.sh uninstall
opkg remove amneziawg
```

## Main components

| Component | Purpose |
|---|---|
| `amneziawg-go` | Userspace implementation of AmneziaWG |
| `awg` | CLI for managing the AmneziaWG interface |
| `amneziawg.sh` | Manages AmneziaWG, routing, and network rules |
| `amneziawg_page.asp` | Web interface for Asuswrt-Merlin |

## Acknowledgements

- AmneziaWG — protocol and implementations
- [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) — router firmware
- [Entware](https://github.com/Entware/Entware) — package system
- [Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip) — GeoIP lists
- [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) — domain lists
- [DanielLavrushin/asuswrt-merlin-xrayui](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui) — architectural reference

## Legal information

The software is provided solely for technical and research purposes.

Users are solely responsible for complying with the laws of the country in which the software is used.

The project author is not responsible for use of the software in violation of applicable law.

## License

MIT License
