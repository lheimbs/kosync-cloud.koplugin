# File-based read progress sync using cloud services

Read progress synchronization for KOReader using a configured cloud service (SyncService).

## Overview

This plugin syncs reading progress by storing progress records in a local SQLite database and synchronizing that database via the existing SyncService (WebDAV/Dropbox). It mirrors KOSync’s behavior and settings while replacing the HTTP server with file-based cloud sync.

## Setup

1. Configure a cloud service and select a folder.
2. Open the plugin menu “Progress sync (cloud)”.
3. Select “Cloud sync” and choose the same cloud folder on each device.

## Usage

- Use “Push progress from this device now” to upload current progress.
- Use “Pull progress from other devices now” to download the latest progress.
- Enable auto sync to sync on suspend/resume and on periodic page turns.

## Data storage

- Local DB: settings directory, file `kosync_cloud_progress.sqlite3`.
- Records are keyed by document digest (MD5, file- or content-based).

## Notes

- The plugin is file-sync based and does not require the KOReader Sync HTTP server.
- Sync logic uses the same merge strategy pattern as the Statistics plugin.
