#!/bin/bash
set -euo pipefail
package=$1
secret=$2
stamp=$3
base=/opt/lifepages
release="$base/releases/$stamp"
site=/etc/nginx/sites-enabled/onesay.top
rates=/etc/nginx/conf.d/lifepages-rates.conf
backup="/etc/nginx/backups/onesay.top.pre-lifepages-$stamp"
if [ -e "$base" ] || [ -e "$rates" ] || grep -q 'LifePages begin' "$site"; then echo '已有 LifePages 部署或路由，停止以避免覆盖'; exit 1; fi
if ss -ltn | awk '{print $4}' | grep -qE '(^|:)8041$'; then echo '8041 端口已占用'; exit 1; fi
if [ "$(sha256sum "$site" | cut -d' ' -f1)" != 47ec23ef1a1f1f88ee6c91e7e59e350bd148cf2be645110505b6367e0b5c17b1 ]; then echo '站点配置自检查后已变化，停止'; exit 1; fi
id lifepages >/dev/null 2>&1 || useradd --system --home-dir "$base" --shell /usr/sbin/nologin lifepages
mkdir -p "$release" "$base/shared/data"
chmod 700 "$base/shared/data"
chown lifepages:lifepages "$base/shared/data"
tar -xzf "$package" -C "$release"
install -m 600 -o root -g root "$secret" "$base/shared/lifepages.env"
rm -f "$secret" "$package"
python3 -m venv "$base/shared/venv"
"$base/shared/venv/bin/pip" install --disable-pip-version-check -q -r "$release/server/requirements.txt"
ln -s "$release" "$base/current"
install -m 644 "$release/deploy/lifepages.service" /etc/systemd/system/lifepages.service
systemctl daemon-reload
systemctl enable --now lifepages.service
for i in $(seq 1 20); do if systemctl is-active --quiet lifepages.service && curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8041/api/people | grep -q '^401$'; then break; fi; sleep 1; done
systemctl is-active --quiet lifepages.service
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8041/api/people)" = 401 ]
mkdir -p /etc/nginx/backups
cp -a "$site" "$backup"
install -m 644 "$release/deploy/nginx-lifepages.conf" "$rates"
python3 - "$site" "$release/deploy/nginx-location.conf" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); source = p.read_text(); marker = '    server_name onesay.top www.onesay.top;'
assert source.count(marker) == 2
p.write_text(source.replace(marker, marker + '\n' + Path(sys.argv[2]).read_text(), 1))
PY
if ! nginx -t; then cp -a "$backup" "$site"; rm -f "$rates"; exit 1; fi
if ! systemctl reload nginx; then cp -a "$backup" "$site"; rm -f "$rates"; nginx -t && systemctl reload nginx; exit 1; fi
printf 'LifePages 服务及专用 HTTPS 路由已启用。\n'
