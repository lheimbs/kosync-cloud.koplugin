# File-based read progress sync using cloud services

Synchronize your read progress with the same cloud provider you use for your your books or your Reading Statistics (Dropbox/WebDAV/FTP/...).

This adds a file-based alternative to the HTTP-based [Progress Sync](https://github.com/koreader/koreader/wiki/Progress-sync) service if you are already using another cloud sync service and don't want to depend on yet another service.

## Installation

1. Copy this folder to your KOReader `plugins` directory (make sure it is named `kosync-cloud.koplugin`)
1. Restart KOReader.
1. Enable **Progress sync (cloud)** from the plugins menu.

## Usage

Cloud service based progress sync is managed from the tools-menu:

![Progress sync (cloud) settings menu](https://github.com/user-attachments/assets/73936721-fdd7-4d07-9fa5-fcd4da5f780a)
![Progress sync (cloud) settings options](https://github.com/user-attachments/assets/635030d5-99cf-4d7d-b66d-233ba8c6cc55)

The settings mimic the original Progress sync plugin:

- Enable auto sync to sync on suspend/resume and (optionally) on periodic page turns.
- Use “Push progress from this device now” to upload current progress.
- Use “Pull progress from other devices now” to download the latest progress.
- Configure the sync behavior when a newer or older state is detected: Either prompt, accept the state silently or ignore the state.
  The prompt looks like this: ![Update progress prompt](https://github.com/user-attachments/assets/ab711e4d-7803-4e9b-b7c9-9984ea5e32a1)
- Configure how documents are matched: Either syncing only identical files or match files based on the file name.

## Data storage

The progress is stored in a sqlite database which is synced to the cloud storage.
The database is named `kosync_cloud_progress.sqlite3`.
Books are keyed by document digest (MD5, file- or content-based depending on the document matching setting).

## WireGuard VPN support (optional)

The plugin can route sync traffic through a WireGuard VPN tunnel using [wireproxy](https://github.com/pufferffish/wireproxy), which exposes the tunnel as a local SOCKS5 proxy.

### Building wireproxy

You need to cross-compile wireproxy for your device. A static ARM binary is suitable for most Android-based e-readers (Kindle, Kobo, etc.).

**Prerequisites:** [Go](https://go.dev/dl/) 1.21 or later.

```bash
# Clone wireproxy
git clone https://github.com/pufferffish/wireproxy.git
cd wireproxy

# Cross-compile a static ARMv7 binary (Android 4.4+ compatible)
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -ldflags="-s -w" -o wireproxy ./cmd/wireproxy

# For AArch64 devices (newer Kobos, etc.)
# CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o wireproxy ./cmd/wireproxy
```

Copy the resulting `wireproxy` binary to your device (e.g. into the KOReader directory or any accessible path).

### WireGuard configuration

Create a standard WireGuard configuration file (`.conf`) with your VPN provider or self-hosted server. The plugin will automatically append the necessary `[Socks5]` section at runtime — you do not need to add it yourself. Example:

```ini
[Interface]
PrivateKey = <your-private-key>
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <server-public-key>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0
```

### Plugin setup

1. In KOReader, open **Progress sync (cloud) → WireGuard VPN (SOCKS5 proxy)**.
2. Select the path to your compiled `wireproxy` binary.
3. Select the path to your WireGuard `.conf` file.
4. Use **Test connection** to verify the tunnel comes up and the SOCKS5 proxy is reachable.
5. Once configured, all sync operations will automatically route through the VPN.
