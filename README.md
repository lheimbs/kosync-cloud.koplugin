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
