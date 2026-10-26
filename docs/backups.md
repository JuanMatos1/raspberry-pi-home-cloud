# Backups and restore validation

## Storage design

JuanCloud stores its live Ubuntu, Docker, Nextcloud application and data on an NVMe drive. A separate external ext4 drive is mounted at `/srv/backups` and stores backup sets:

```text
/srv/backups/
├── databases/       # nextcloud-TIMESTAMP.sql logical PostgreSQL dump
├── nextcloud/        # nextcloud-data-TIMESTAMP.tar.gz Nextcloud volume archive
└── server-config/    # TIMESTAMP/SHA256SUMS and recovery-related configuration
```

The live backup timer is `juancloud-backup.timer`; its documented daily schedule is around **03:00 UTC**. Check the current configuration on the server rather than assuming an old screenshot represents present operation.

```bash
findmnt /srv/backups
sudo systemctl status juancloud-backup.timer --no-pager
sudo systemctl show juancloud-backup.service -p Result -p ExecMainStatus
sudo systemctl list-timers --all | grep juancloud-backup
```

The backup service has previously reported success. A completed backup job alone does **not** establish recoverability.

## Verified restore test — October 26, 2026

The following claims are grounded in test output from the live Raspberry Pi:

- SQL and tar backup files passed the recorded SHA256 checksums.
- The archive was readable and contained 25,252 files, including `config/config.php` and `data/.ncdata`.
- A **separate** PostgreSQL 17 container successfully imported 126 application tables. The restored application's PostgreSQL role `oc_admin` needed to be created first.
- An independent Nextcloud working copy was extracted and tested with temporary PostgreSQL, Redis and Nextcloud containers. Two CLI recovery tests succeeded in 15 seconds each.
- HTTP `status.php` returned `200 OK` and `installed:true`; the restored site was accessed through an SSH tunnel and the user verified that files were visible in the browser.
- No temporary recovery Docker containers, volumes or networks remained after cleanup.

The 15-second duration covers the on-device CLI exercise on already-functioning hardware and is **not** a complete disaster-recovery RTO. Individual restored file contents were not separately documented as opened/downloaded.

For the full workflow, troubleshooting, architecture and commands, see [JuanCloud v3 disaster recovery](juancloud-v3-disaster-recovery.md).

## Open risks and planned work

- **Off-site:** The external backup is local to the Pi. Add a separately stored encrypted copy, verify retrieval/decryption and practice recovery without the original Pi.
- **PostgreSQL globals:** Add a protected method for backing up global roles (`pg_dumpall --globals-only`) and review ownership/privilege restoration rather than manually rebuilding roles every time.
- **Retention and pruning:** Document, test, and monitor actual retention logic before making any retention SLA claim.
- **Formal RPO/RTO:** Measure complete elapsed time and acceptable data-loss window, including provisioning and restoring on replacement hardware.
- **Recovery cadence:** Schedule repeatable independent restore tests and alerts on failure.
- **Application updates:** Use version-compatible Nextcloud and PostgreSQL images during restoration; avoid auto-upgrading the restored database as part of the initial recovery.

**Privacy:** Do not commit `.env`, `config.php`, the SQL dump, user files, backup archives, credentials, encrypted backup keys, or the external monitor's Ping URL.
