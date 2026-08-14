#!/usr/bin/env bash
# image/etc/apache2/conf-available/99-minivps-hardening.conf の構文チェック。
# 前提: apache2(未導入なら `sudo apt install apache2`)。
#
# 実機の /etc/apache2 全体ではなく本リポジトリのファイルだけを検証したいため、
# check-bind.sh と同じ「一時ディレクトリに検証専用の設定を組み立てる」方式をとる。
# 対象の3ディレクティブはcoreだが、apache2は設定の内容によらずMPMが1つ
# ロードされていないと起動を拒否するため、最小configにもMPMのLoadModuleが要る。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="${APACHE_MODULES_DIR:-/usr/lib/apache2/modules}"

command -v apache2 >/dev/null || {
  echo "missing: apache2 (sudo apt install apache2)" >&2
  exit 1
}
[ -r "$MODULES_DIR/mod_mpm_event.so" ] || {
  echo "missing: $MODULES_DIR/mod_mpm_event.so (APACHE_MODULES_DIR で場所を指定できる)" >&2
  exit 1
}

CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT

cat > "$CHECK_DIR/httpd.conf" <<EOF
ServerRoot "$CHECK_DIR"
PidFile "$CHECK_DIR/apache2.pid"
ErrorLog "$CHECK_DIR/error.log"
LoadModule mpm_event_module "$MODULES_DIR/mod_mpm_event.so"
Include "$REPO_ROOT/image/etc/apache2/conf-available/99-minivps-hardening.conf"
EOF

echo "==> apache2 -t(最小configにIncludeして検証)"
# APACHE_* 環境変数はDebian/Ubuntuのapache2バイナリが起動時に参照する。
# envvars自身が未定義変数を参照するため、読み込みの間だけ set -u を外す。
if [ -r /etc/apache2/envvars ]; then
  set +u
  . /etc/apache2/envvars
  set -u
fi
apache2 -t -f "$CHECK_DIR/httpd.conf"
echo "OK: Apache設定の構文チェックに通りました"
