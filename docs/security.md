# Security

## Implemented controls

- SSH public-key authentication; password authentication disabled.
- Root SSH access disabled.
- Unique private key per authorized client device.
- UFW default-deny policy for incoming traffic.
- No router port forwarding.
- Nextcloud and the dashboard bind only to loopback addresses.
- Tailscale Serve provides private HTTPS inside the authenticated tailnet.
- Tailscale Funnel is not enabled.
- Secrets live in ignored `.env` files; only `.env.example` is committed.
- PostgreSQL and Redis use separate credentials.
- Dashboard container runs without root, privilege escalation or Linux capabilities.
- Dashboard filesystem and metrics mounts are read-only.
- Docker socket, logs, tokens and administrative controls are not exposed to the dashboard.
- Ubuntu unattended security updates are enabled.

## Verification commands

```bash
sudo sshd -T | grep -E 'passwordauthentication|pubkeyauthentication|permitrootlogin'
sudo ufw status verbose
systemctl is-enabled unattended-upgrades
tailscale serve status
```

Expected SSH policy:

```text
passwordauthentication no
pubkeyauthentication yes
```

## Key handling

Private keys never leave their client devices. Public keys are stored one per line in:

```text
/home/juanmatos/.ssh/authorized_keys
```

Recommended permissions:

```bash
chmod 700 /home/juanmatos
chmod 700 /home/juanmatos/.ssh
chmod 600 /home/juanmatos/.ssh/authorized_keys
```

Do not publish `.env`, private SSH keys, Tailnet addresses, host fingerprints, database dumps or backup archives.

