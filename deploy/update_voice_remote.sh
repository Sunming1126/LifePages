#!/bin/bash
set -euo pipefail
base=/opt/lifepages
previous=$(readlink -f "$base/current")
[ "$previous" = /opt/lifepages/releases/20261105-chat-v2 ] || { echo '当前版本变化，停止'; exit 1; }
release="$base/releases/20261105-onesay-voice"
[ ! -e "$release" ] || exit 1
systemctl is-active --quiet lifepages
mkdir "$release"
cp -a "$previous/." "$release/"
tar -xzf /tmp/lifepages-voice.tar.gz -C "$release"
rm -f /tmp/lifepages-voice.tar.gz
rollback() {
  ln -sfn "$previous" "$base/current.restore"
  mv -Tf "$base/current.restore" "$base/current"
  systemctl restart lifepages
}
trap rollback ERR
ln -s "$release" "$base/current.next"
mv -Tf "$base/current.next" "$base/current"
systemctl restart lifepages
for i in $(seq 1 20); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8041/api/people)" = 401 ]; then break; fi
  sleep 1
done
[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8041/api/people)" = 401 ]
trap - ERR
printf 'LifePages 语音凭证接口已更新。\n'
