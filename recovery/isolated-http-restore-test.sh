#!/usr/bin/env bash
# JuanCloud v3: isolated short-lived HTTP and browser recovery validation.
# No Docker ports are published; private Docker bridge IP is reached only via SSH forwarding.
# Does not touch production Docker volumes, Compose services, or Tailscale Serve.
set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
  printf 'Run using: sudo bash %s\n' "$0" >&2
  exit 1
fi

STAMP="${1:-}"
if [[ ! "$STAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Usage: sudo bash $0 YYYY-MM-DD_HH-MM-SS" >&2
  exit 2
fi
BASE='/srv/projects/juancloud-dr'
SOURCE="${BASE}/restore-${STAMP}"
SQL="/srv/backups/databases/nextcloud-${STAMP}.sql"
MANIFEST="/srv/backups/server-config/${STAMP}/SHA256SUMS"
SESSION="${BASE}/sessions/dr-$(date +%Y%m%dT%H%M%SZ)-$$"
RUN_ID="$(date +%s)-$$"
NETWORK="juancloud-dr-net-${RUN_ID}"
PG="juancloud-dr-db-${RUN_ID}"
REDIS="juancloud-dr-redis-${RUN_ID}"
APP="juancloud-dr-app-${RUN_ID}"
VOL="juancloud-dr-db-${RUN_ID}-data"
NETWORK_CREATED=0
VOLUME_CREATED=0
START=$SECONDS
HOST_PORT=18090 # Windows-local SSH tunnel port; not published on Raspberry Pi.
if ! command -v curl >/dev/null 2>&1; then
  echo 'STOP: curl is required on the Raspberry Pi.' >&2
  exit 1
fi

cleanup() {
  local status=$?
  trap - EXIT
  set +e
  docker rm -f "$APP" "$PG" "$REDIS" >/dev/null 2>&1
  if (( VOLUME_CREATED )); then docker volume rm "$VOL" >/dev/null 2>&1; fi
  if (( NETWORK_CREATED )); then docker network rm "$NETWORK" >/dev/null 2>&1; fi
  if [[ -n "${SESSION:-}" && "$SESSION" == "${BASE}/sessions/dr-"* ]]; then rm -rf -- "$SESSION"; fi
  if (( status == 0 )); then
    echo 'Cleanup: temporary recovery containers, network, storage and credentials removed.'
  else
    echo "FAIL: isolated recovery test stopped (exit code $status); temporary resources cleaned up." >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

printf '%s\n' '=== JuanCloud v3: Isolated Recovery Test ==='
for f in "$MANIFEST" "$SQL" "$SOURCE/config/config.php" "$SOURCE/data/.ncdata" "$SOURCE/occ"; do
  if [[ ! -f "$f" ]]; then echo "STOP: missing required file: $f" >&2; exit 1; fi
done
if [[ ! -d /srv/backups ]] || ! mountpoint -q /srv/backups; then
  echo 'STOP: external backup disk is not mounted.' >&2
  exit 1
fi
if [[ $(awk '/MemAvailable:/ {print $2}' /proc/meminfo) -lt 2097152 ]]; then
  echo 'STOP: less than 2 GiB RAM available; schedule test for a quieter period.' >&2
  exit 1
fi

printf '%s\n' '1. Verifying source backup checksums...'
sha256sum -c "$MANIFEST"

printf '%s\n' '2. Verifying production images are cached locally...'
NC_IMAGE="$(docker inspect -f '{{.Image}}' juancloud-nextcloud-app-1)"
PG_IMAGE="$(docker inspect -f '{{.Image}}' juancloud-nextcloud-db-1)"
REDIS_IMAGE="$(docker inspect -f '{{.Image}}' juancloud-nextcloud-redis-1)"
for img in "$NC_IMAGE" "$PG_IMAGE" "$REDIS_IMAGE"; do docker image inspect "$img" >/dev/null; done

printf '%s\n' '3. Preparing a private working copy (production and extracted original remain untouched)...'
install -d -m 700 "${BASE}/sessions" "${BASE}/reports"
install -d -m 700 "$SESSION"
cp -a -- "$SOURCE" "$SESSION/app"
chown -R 33:33 "$SESSION/app"
# Deliberately replace all production config snippets in the TEMPORARY working copy.
rm -rf -- "$SESSION/app/config"
install -d -o 33 -g 33 -m 750 "$SESSION/app/config"
DR_PASSWORD="$(openssl rand -hex 24)"

# Generate a minimal config from the backed-up Nextcloud identity keys. No credentials printed.
# This offline helper has no network and only receives a read-only mount of the source config.
if ! docker run --rm --network none --entrypoint php \
     -v "$SOURCE/config/config.php:/source/config.php:ro" \
     -e DR_PASSWORD="$DR_PASSWORD" "$NC_IMAGE" -r '
$CONFIG = [];
include "/source/config.php";
$keep = ["instanceid", "passwordsalt", "secret", "version", "installed", "dbtype", "dbtableprefix", "default_phone_region"];
$out = [];
foreach ($keep as $key) { if (array_key_exists($key, $CONFIG)) $out[$key] = $CONFIG[$key]; }
foreach (["instanceid", "passwordsalt", "secret"] as $required) {
    if (empty($out[$required])) { fwrite(STDERR, "Missing recovery identity key: {$required}\n"); exit(2); }
}
$out["installed"] = true;
$out["dbtype"] = "pgsql";
$out["dbname"] = "nextcloud";
$out["dbhost"] = "db";
$out["dbuser"] = "oc_admin";
$out["dbpassword"] = getenv("DR_PASSWORD");
$out["datadirectory"] = "/var/www/html/data";
$out["trusted_domains"] = ["localhost", "127.0.0.1"];
$out["overwrite.cli.url"] = "http://localhost:18090";
$out["maintenance"] = false;
$out["redis"] = ["host" => "redis", "port" => 6379];
$out["memcache.locking"] = "\\OC\\Memcache\\Redis";
$out["upgrade.disable-web"] = true;
$out["updatechecker"] = false;
$out["logfile"] = "/var/www/html/data/nextcloud-recovery.log";
echo "<?php\n\$CONFIG = " . var_export($out, true) . ";\n";
' > "$SESSION/app/config/config.php"; then
  echo 'FAIL: could not build isolated Nextcloud configuration.' >&2
  exit 1
fi
chown 33:33 "$SESSION/app/config/config.php"
chmod 640 "$SESSION/app/config/config.php"

printf '%s\n' '4. Starting isolated PostgreSQL 17 + Redis 8 (no published ports; internal network)...'
docker network create --internal "$NETWORK" >/dev/null
NETWORK_CREATED=1
docker volume create "$VOL" >/dev/null
VOLUME_CREATED=1

docker run -d --name "$PG" --network "$NETWORK" --network-alias db \
  --memory 768m --cpus 1 \
  -e POSTGRES_USER=nextcloud -e POSTGRES_DB=nextcloud \
  -e POSTGRES_PASSWORD="$DR_PASSWORD" \
  -v "$VOL:/var/lib/postgresql/data" "$PG_IMAGE" >/dev/null

docker run -d --name "$REDIS" --network "$NETWORK" --network-alias redis \
  --memory 128m --cpus 0.5 "$REDIS_IMAGE" redis-server --save '' --appendonly no >/dev/null

ready=0
for i in $(seq 1 60); do
  if docker exec "$PG" pg_isready -q -U nextcloud -d nextcloud; then ready=1; break; fi
  sleep 1
done
if (( ! ready )); then echo 'FAIL: temporary PostgreSQL did not become ready.' >&2; exit 1; fi

printf '%s\n' '5. Creating isolated application login and restoring the SQL dump...'
printf "CREATE ROLE oc_admin LOGIN PASSWORD '%s';\n" "$DR_PASSWORD" | \
  docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U nextcloud -d nextcloud >/dev/null
cat "$SQL" | docker exec -i "$PG" psql -v ON_ERROR_STOP=1 -U nextcloud -d nextcloud >/dev/null
TABLES=$(docker exec "$PG" psql -U nextcloud -d nextcloud -At -c \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public';")
if [[ "$TABLES" -lt 1 ]]; then echo 'FAIL: no recovered application tables.' >&2; exit 1; fi
printf 'PASS: %s database tables restored.\n' "$TABLES"

printf '%s\n' '6. Starting temporary Nextcloud HTTP server on a private Docker bridge...'
# This image is the already-cached, production-matching immutable image ID.
# No production mounts; the recovered app directory is a temporary copy.
docker run -d --name "$APP" --network "$NETWORK" --network-alias recovery-app \
  --memory 1400m --cpus 1.5 \
  -v "$SESSION/app:/var/www/html:rw" \
  "$NC_IMAGE" >/dev/null

# Host processes can connect to containers on a Docker internal bridge by IP;
# Docker's -p publishing may fail when that bridge is --internal.
APP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$APP")"
if [[ ! "$APP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'FAIL: no valid temporary private container IP was assigned.' >&2
  exit 1
fi
echo 'Testing HTTP directly on the temporary private Docker bridge (no published ports)...'

# Demonstrate actual HTTP responses, not only the success of occ commands.
READY=0
for i in $(seq 1 45); do
  if curl --noproxy '*' --silent --fail --max-time 3 \
     --connect-to "127.0.0.1:${HOST_PORT}:${APP_IP}:80" \
     "http://127.0.0.1:${HOST_PORT}/status.php" | \
     python3 -c 'import sys,json; x=json.load(sys.stdin); assert x.get("installed") is True' 2>/dev/null; then
    READY=1
    break
  fi
  sleep 2
done
if (( ! READY )); then
  echo 'FAIL: recovered Nextcloud did not serve a valid installed=true status.php.' >&2
  echo 'Diagnostic: checking status.php HTTP code on private bridge (no response body shown)...' >&2
  curl --noproxy '*' -sS -o /dev/null -w 'HTTP status: %{http_code}; connection IP: %{remote_ip}\n' \
    --max-time 5 --connect-to "127.0.0.1:${HOST_PORT}:${APP_IP}:80" \
    "http://127.0.0.1:${HOST_PORT}/status.php" >&2 || true
  exit 1
fi
printf '%s\n' 'PASS: Restored Nextcloud status.php returned installed=true over HTTP.'

printf '%s\n' '7. Validating recovered Nextcloud CLI and SQL-backed application metadata...'
docker exec -u www-data "$APP" php /var/www/html/occ status
docker exec -u www-data "$APP" php /var/www/html/occ app:list --output=json >/dev/null
printf '%s\n' 'PASS: Restored Nextcloud can query its isolated PostgreSQL database.'

printf '%s\n' '8. Checking the login page through isolated HTTP...'
LOGIN_CODE="$(curl --noproxy '*' --silent --location --output /dev/null --write-out '%{http_code}' \
     --max-time 15 --connect-to "127.0.0.1:${HOST_PORT}:${APP_IP}:80" \
     "http://127.0.0.1:${HOST_PORT}/login")"
if [[ "$LOGIN_CODE" != '200' ]]; then
  echo "NOTE: /login HTTP status was $LOGIN_CODE; inspect browser output if necessary."
else
  echo 'PASS: /login returned HTTP 200.'
fi

DURATION=$((SECONDS - START))
REPORT="${BASE}/reports/http-restore-${STAMP}-$(date +%Y%m%dT%H%M%SZ).txt"
printf 'Backup: %s\nSHA256 verification: passed\nRestored tables: %s\nCLI installed status: passed\nHTTP status.php: passed\nLogin status: %s\nElapsed until HTTP test: %s seconds\nBrowser file-opening verification: not yet performed\n' \
  "$STAMP" "$TABLES" "$LOGIN_CODE" "$DURATION" > "$REPORT"
chmod 600 "$REPORT"
printf 'Local non-secret report: %s\n' "$REPORT"
cat <<'MESSAGE'

============================================================
TEMPORARY RECOVERY SITE IS ACTIVE FOR UP TO 10 MINUTES.

On WINDOWS, open a SECOND PowerShell window and run:
MESSAGE
printf '  ssh -N -L 127.0.0.1:%s:%s:80 -i "PATH_TO_SSH_PRIVATE_KEY" SSH_USER@TAILSCALE_HOST\n' \
  "$HOST_PORT" "$APP_IP"
cat <<'MESSAGE'

Then open this URL in a browser on that Windows PC:
  http://127.0.0.1:18090/login

Confirm it is the RESTORED instance. If you sign in,
use only a test account or an authorized existing account;
its copied database and files are isolated from production.
Do NOT upload new files or use it for normal sync.

When finished, RETURN TO THIS PI TERMINAL and press Enter.
If you don't press Enter, cleanup starts after 10 minutes.
============================================================
MESSAGE

# Automatically close the temporary service after ten minutes.
# readline exits early on Enter; a timeout is not an error.
read -r -t 600 -p 'Press Enter to shut down the recovery test: ' _ || true
printf '\nStopping recovered test environment...\n'
