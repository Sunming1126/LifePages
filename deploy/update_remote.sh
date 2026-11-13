#!/bin/bash
# Update only LifePages. The caller supplies an archive and the version observed before deployment.
set -euo pipefail
package=$1
stamp=$2
expected=$3
expected_nginx=$4
base=/opt/lifepages
release="$base/releases/$stamp"
site=/etc/nginx/sites-enabled/onesay.top
site_backup="/etc/nginx/backups/onesay.top.pre-lifepages-$stamp"
previous=$(readlink -f "$base/current")
[ "$previous" = "$expected" ] || { echo 'LifePages 当前版本已变化，停止'; exit 1; }
[ "$(sha256sum "$site" | cut -d' ' -f1)" = "$expected_nginx" ] || { echo 'Nginx 配置已变化，停止'; exit 1; }
[ ! -e "$release" ] || { echo '发布目录已存在，停止'; exit 1; }
[ ! -e /etc/systemd/system/lifepages-drafts.timer ] || { echo '整理定时器已存在，停止以免覆盖'; exit 1; }
systemctl is-active --quiet lifepages.service
nginx -t
mkdir -p "$release" "$base/backups/$stamp"
chmod 700 "$base/backups" "$base/backups/$stamp"
tar -xzf "$package" -C "$release"
rm -f "$package"
# SQLite online backups provide a consistent copy without modifying live data.
python3 - "$base/shared/data" "$base/backups/$stamp" <<'PY'
import os, sqlite3, sys
from pathlib import Path
root, destination = map(Path, sys.argv[1:])
for source in [root / 'registry.sqlite3', *sorted((root / 'accounts').glob('*/lifepages.sqlite3'))]:
    if not source.is_file():
        continue
    target = destination / source.relative_to(root)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with sqlite3.connect(f'file:{source}?mode=ro', uri=True) as src, sqlite3.connect(target) as dst:
        src.backup(dst)
    os.chmod(target, 0o600)
PY
cp -a "$site" "$site_backup"
# The public voice route is isolated from existing projects and uses authenticated WebSocket upgrades.
python3 - "$site" <<'PY'
from pathlib import Path
import sys
site = Path(sys.argv[1]); text = site.read_text()
marker = '    # LifePages begin\n'
assert text.count(marker) == 1 and 'location ^~ /lifepages/api/voice/' not in text
block = '''    location ^~ /lifepages/api/voice/ {
        limit_req zone=lifepages_api burst=30 nodelay;
        limit_req_status 429;
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:8041/api/voice/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
'''
site.write_text(text.replace(marker, marker + block, 1))
PY
if ! nginx -t; then cp -a "$site_backup" "$site"; exit 1; fi
rollback() {
  ln -sfn "$previous" "$base/current.rollback"
  mv -Tf "$base/current.rollback" "$base/current"
  systemctl restart lifepages.service || true
  cp -a "$site_backup" "$site"
  nginx -t && systemctl reload nginx || true
  systemctl disable --now lifepages-drafts.timer 2>/dev/null || true
}
trap rollback ERR
ln -s "$release" "$base/current.next"
mv -Tf "$base/current.next" "$base/current"
systemctl restart lifepages.service
for i in $(seq 1 25); do
  if systemctl is-active --quiet lifepages.service && [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8041/api/people)" = 401 ]; then break; fi
  sleep 1
done
systemctl is-active --quiet lifepages.service
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8041/api/people)" = 401 ]
systemctl reload nginx
install -m 644 "$release/deploy/lifepages-drafts.service" /etc/systemd/system/lifepages-drafts.service
install -m 644 "$release/deploy/lifepages-drafts.timer" /etc/systemd/system/lifepages-drafts.timer
systemctl daemon-reload
systemctl enable --now lifepages-drafts.timer
systemctl is-active --quiet lifepages-drafts.timer
trap - ERR
printf 'LifePages 发布成功，旧版本和数据备份已保留。\n'
