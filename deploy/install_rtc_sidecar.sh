#!/bin/bash
# First install only. This adds one LifePages route and leaves the existing services running.
set -euo pipefail
archive=$1
stamp=$2
voice=$3
resource=$4
[[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z-rtc$ ]]
base=/opt/lifepages/rtc
release="$base/releases/$stamp"
unit=/etc/systemd/system/lifepages-rtc.service
site=/etc/nginx/sites-enabled/onesay.top
site_backup="$base/onesay.top.before-$stamp"
exec 9>/run/lock/lifepages-rtc-install.lock
flock -n 9

[ ! -e "$base" ] && [ ! -e "$unit" ]
[ -f "$site" ] && [ ! -L "$site" ]
! grep -Fq '/lifepages/api/rtc/' "$site"
[ -z "$(ss -H -ltn '( sport = :8045 )')" ]
systemctl is-active --quiet lifepages.service
systemctl is-active --quiet nginx.service
nginx -t

http_code() {
  curl --silent --show-error --max-time 8 --resolve onesay.top:443:127.0.0.1 \
    --output /dev/null --write-out '%{http_code}' "https://onesay.top$1"
}
baseline() {
  systemctl show lifepages.service nginx.service -p MainPID -p ActiveState --value
  readlink -f /opt/lifepages/current /opt/saypal/voice/current
  for path in / /lifepages/api/people /saypal/voice/health; do http_code "$path"; printf '\n'; done
}
before=$(baseline)

install -d -m 755 "$release"
install -m 600 "$site" "$site_backup"
tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$release"
python3 "$release/deploy/prepare_rtc_env.py" /opt/saypal/voice/shared/.env "$base/rtc.env" \
  --voice "$voice" --resource "$resource"

site_changed=0
route_loaded=0
rollback() {
  local code=$?
  trap - ERR
  set +e
  if [ "$site_changed" = 1 ]; then
    if [ "$(sha256sum "$site" | cut -d' ' -f1)" = "$patched_hash" ]; then
      cat "$site_backup" > "$site"
      if [ "$route_loaded" = 1 ]; then nginx -t && systemctl reload nginx; fi
    else
      printf '%s\n' 'Nginx 配置同时被修改，请检查 RTC 路由，已保留独立服务。' >&2
      exit "$code"
    fi
  fi
  systemctl disable --now lifepages-rtc.service >/dev/null 2>&1 || true
  if [ -f "$unit" ]; then rm -f "$unit"; systemctl daemon-reload; fi
  exit "$code"
}
trap rollback ERR
ln -s "$release" "$base/current"
install -m 644 "$release/deploy/lifepages-rtc.service" "$unit"
systemctl daemon-reload
systemctl enable --now lifepages-rtc.service
for attempt in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:8045/health 2>/dev/null | grep -Fq '"rtcConfigured":true'; then break; fi
  sleep 1
done
systemctl is-active --quiet lifepages-rtc.service
curl -fsS --max-time 2 http://127.0.0.1:8045/health | grep -Fq '"rtcConfigured":true'
cmp -s "$site" "$site_backup"

python3 - "$site" "$base/nginx-$stamp.conf" <<'PY'
from pathlib import Path
import sys

site, candidate = map(Path, sys.argv[1:])
original = site.read_text()
marker = '    # LifePages begin\n'
assert original.count(marker) == 1
route = '''    # LifePages RTC reply playback
    location ^~ /lifepages/api/rtc/ {
        limit_req zone=lifepages_rtc burst=160 nodelay;
        limit_req_status 429;
        access_log off;
        error_log /dev/null crit;
        client_max_body_size 2k;
        proxy_pass http://127.0.0.1:8045/api/rtc/;
        proxy_set_header Host $host;
        proxy_connect_timeout 2s;
        proxy_read_timeout 25s;
    }
'''
candidate.write_text(original.replace(marker, marker + route, 1))
PY
patched_hash=$(sha256sum "$base/nginx-$stamp.conf" | cut -d' ' -f1)
cmp -s "$site" "$site_backup"
cat "$base/nginx-$stamp.conf" > "$site"
site_changed=1
nginx -t
route_loaded=1
systemctl reload nginx
for attempt in $(seq 1 15); do
  status=$(curl --silent --show-error --max-time 5 --resolve onesay.top:443:127.0.0.1 \
    --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"message_id":"00000000000000000000000000000000"}' \
    https://onesay.top/lifepages/api/rtc/sessions)
  if [ "$status" = 401 ]; then break; fi
  sleep 1
done
[ "$status" = 401 ]
after=$(baseline)
[ "$before" = "$after" ]
trap - ERR
printf 'RTC release: %s\nExisting service baseline before and after:\n%s\nRTC HTTPS auth: %s\n' "$release" "$after" "$status"
