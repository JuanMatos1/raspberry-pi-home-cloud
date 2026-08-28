# Troubleshooting

## Confirm the active boot disk

```bash
findmnt /
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL
```

The root filesystem should be mounted from the NVMe partition, not the microSD.

## Inspect Docker services

```bash
cd /srv/nextcloud
sudo docker compose ps
sudo docker compose logs --tail=100 app db redis cron
```

Dashboard:

```bash
cd /srv/projects/test-api
sudo docker compose ps
sudo docker compose logs --tail=100 api
curl http://127.0.0.1:3000/health
```

## Check private access

```bash
tailscale status
tailscale serve status
```

From an authorized Windows client:

```powershell
tailscale ping juancloud
ssh juancloud
```

## SSH rejects a key

```bash
chmod 700 /home/juanmatos
chmod 700 /home/juanmatos/.ssh
chmod 600 /home/juanmatos/.ssh/authorized_keys
sudo chown -R juanmatos:juanmatos /home/juanmatos/.ssh
ssh-keygen -lf /home/juanmatos/.ssh/authorized_keys
```

Compare that fingerprint with the `.pub` file on the client. Never transmit the private-key file.

## Backup disk missing

```bash
lsblk -f
findmnt /srv/backups
sudo mount -a
```

Do not reformat a disk during troubleshooting unless its identity and contents have been independently confirmed.

