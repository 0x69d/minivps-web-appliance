#!/usr/bin/env bash
# image/etc/apache2/conf-available/99-minivps-hardening.conf の構文チェック。
# 前提: apache2(未導入なら `sudo apt install apache2`)。
#
# 実機の /etc/apache2 全体ではなく本リポジトリのファイルだけを検証したいため、
# check-bind.sh と同じ「一時ディレクトリに検証専用の設定を組み立てる」方式をとる。
# 対象の3ディレクティブはいずれもcoreでモジュール非依存なので、LoadModuleを
# 一切書かない最小configでよい。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v apache2 >/dev/null || {
  echo "missing: apache2 (sudo apt install apache2)" >&2
  exit 1
}

CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT

cat > "$CHECK_DIR/httpd.conf" <<EOF
ServerRoot "$CHECK_DIR"
PidFile "$CHECK_DIR/apache2.pid"
ErrorLog "$CHECK_DIR/error.log"
Include "$REPO_ROOT/image/etc/apache2/conf-available/99-minivps-hardening.conf"
EOF

echo "==> apache2 -t(最小configにIncludeして検証)"
# APACHE_* 環境変数はDebian/Ubuntuのapache2バイナリが起動時に参照する。
[ -r /etc/apache2/envvars ] && . /etc/apache2/envvars
apache2 -t -f "$CHECK_DIR/httpd.conf"
echo "OK: Apache設定の構文チェックに通りました"
