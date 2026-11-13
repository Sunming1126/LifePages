#!/bin/bash
set -euo pipefail
base=/opt/lifepages
site=/etc/nginx/sites-enabled/onesay.top
rates=/etc/nginx/conf.d/lifepages-rates.conf
backup=/etc/nginx/backups/onesay.top.pre-lifepages-20261105T1740
release="$base/releases/20261105T1740"
if [ ! -f "$backup" ] || [ -e "$rates" ] || grep -q 'LifePages begin' "$site"; then echo '配置状态与预期不符，停止'; exit 1; fi
if [ "$(sha256sum "$site" | cut -d' ' -f1)" != 47ec23ef1a1f1f88ee6c91e7e59e350bd148cf2be645110505b6367e0b5c17b1 ]; then echo '现有站点配置已变化，停止'; exit 1; fi
systemctl is-active --quiet lifepages.service
install -m 644 /tmp/lifepages-rates-20261105.conf "$release/deploy/nginx-lifepages.conf"
install -m 644 /tmp/lifepages-rates-20261105.conf "$rates"
rm -f /tmp/lifepages-rates-20261105.conf
python3 - "$site" "$release/deploy/nginx-location.conf" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); source = p.read_text(); marker = '    server_name onesay.top www.onesay.top;'
assert source.count(marker) == 2
p.write_text(source.replace(marker, marker + '\n' + Path(sys.argv[2]).read_text(), 1))
PY
if ! nginx -t; then cp -a "$backup" "$site"; rm -f "$rates"; exit 1; fi
if ! systemctl reload nginx; then cp -a "$backup" "$site"; rm -f "$rates"; nginx -t && systemctl reload nginx; exit 1; fi
printf 'LifePages 专用 HTTPS 路由已启用。\n'
