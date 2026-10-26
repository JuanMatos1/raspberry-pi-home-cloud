# Monitoring source snapshot

This directory contains a **sanitized code snapshot exported from the deployed Raspberry Pi**, not live runtime state.

- `monitor.py` — verified local health checks, state-change and daily Gmail emails
- `tests/test_monitor.py` — unit tests for health rules
- `update-notifier.py` — optional APT/dpkg package-change notifier (present only when deployed)
- `enable-auto-updates.sh` — Ubuntu unattended-upgrades configuration
- `update-notifications-install.sh` — optional update-notifier installation script

The repository export intentionally omits `/etc/juancloud-health.env`, `.env`, credential files, log files, APT/dpkg state, backup archives, server data, and external IP/Tailscale addresses.

To run the Python tests locally (no SMTP credentials needed):

```bash
python3 -m unittest discover -s monitoring/tests -v
python3 -m py_compile monitoring/monitor.py
```

**Caution:** The original server-specific monitoring installer patched the deployed Express dashboard and needs local paths and services. This snapshot is for review, not a one-click installer for arbitrary devices. Refer to [operational documentation](../docs/monitoring-and-maintenance.md).
