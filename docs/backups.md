# Backups

## Storage design

The Kingston NVMe is the live storage device. The WD Elements disk is formatted as ext4 and mounted persistently at:

```text
/srv/backups
```

The backup disk contains separate locations for database exports, Nextcloud data and server configuration:

```text
/srv/backups/
├── databases/
├── nextcloud/
└── server-config/
```

## Initial backup completed

The initial recovery set contains:

- A PostgreSQL logical dump.
- A compressed archive of the Nextcloud Docker volume.
- The sanitized Compose configuration.
- A protected copy of the production environment file on the backup disk only.

No backup archive or production secret is committed to GitHub.

## Verification

```bash
findmnt /srv/backups
df -h /srv/backups
sudo ls -lh /srv/backups/databases
sudo ls -lh /srv/backups/nextcloud
sudo ls -lh /srv/backups/server-config
```

## Remaining work

- Create and test an automated scheduled-backup script.
- Define retention and pruning rules.
- Perform a complete restore test into temporary volumes.
- Add an encrypted off-site copy for irreplaceable data.

A backup is not considered proven until restoration has been tested.

