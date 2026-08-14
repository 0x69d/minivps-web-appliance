#!/usr/bin/env bash
# minivps-web-appliance ゴールデンイメージ ビルドスクリプト。
#
# ベースのUbuntu cloud imageに apache2 + nftables + 本リポジトリのゲスト内設定
# (image/etc/**)を焼き込み、libvirtの`images`
# ストレージプールへ新しいボリュームとして配置する。一時VMをcloud-initで
# カスタマイズして起動し、シャットダウン後のディスクをそのままゴールデン
# イメージとして確定する方式。
#
# ディスク/seed ISOの扱いは、mini-vps-platform自身が
# create_overlay_volume()/build_seed_iso()(mini_vps/resources.py)で
# 使っているのと同じlibvirt volume APIに揃えている:
#   - ビルド用ディスクは`images`プール内で`vol-clone`して作る。
#   - seed ISOはmini-vps-platformが使うのと同じ`vps-seeds`プールに
#     vol-create+vol-uploadで配置する。
#
# 出力: `images`プール内に <GOLDEN_IMAGE_NAME> という名前のボリュームとして配置。
# specs/web-1.yaml の base_image をこの名前に書き換えて使う。
set -euo pipefail

BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-ubuntu-26.04.img}"
GOLDEN_IMAGE_NAME="${GOLDEN_IMAGE_NAME:-minivps-web-golden-$(date +%Y%m%d).qcow2}"
BUILD_VM_NAME="minivps-web-build-$$"
BUILD_MEMORY_MB="${BUILD_MEMORY_MB:-1024}"
BUILD_VCPUS="${BUILD_VCPUS:-2}"
# ビルド用ディスクの拡張後サイズ。ubuntu-26.04.img の仮想サイズは3.5GiBで
# rootfsは2.3GiBしか無く、パッケージを足すとすぐ "No space left on device" になる。
# 既定値は specs/web-1.yaml の disk と揃える。ゴールデンイメージの仮想サイズが
# specの disk を超えるとVM作成時のオーバーレイ作成に失敗するため。
BUILD_DISK_SIZE="${BUILD_DISK_SIZE:-10G}"
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/minivps_ed25519.pub}"
IMAGES_POOL="${IMAGES_POOL:-images}"
SEEDS_POOL="${SEEDS_POOL:-vps-seeds}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-600}"

# ビルド中だけ使う固定名の一時volume。成功時のみ最後にGOLDEN_IMAGE_NAMEへ
# vol-cloneで確定させる。失敗時にGOLDEN_IMAGE_NAME名の不完全な
# volumeが残ることを防ぐため。
TEMP_DISK_VOL="minivps-web-build-disk.qcow2"
TEMP_SEED_VOL="minivps-web-build-seed.iso"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d /var/tmp/minivps-web-build.XXXXXX)"

cleanup() {
  # transientドメインはpoweroffで即座にdestroy&削除されるため、
  # 保険としての destroy/undefine はベストエフォートで構わない。
  virsh destroy "$BUILD_VM_NAME" >/dev/null 2>&1 || true
  virsh undefine "$BUILD_VM_NAME" --nvram >/dev/null 2>&1 || true
  # 一時volumeは常に破棄する。
  virsh vol-delete --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" >/dev/null 2>&1 || true
  virsh vol-delete --pool "$SEEDS_POOL" "$TEMP_SEED_VOL" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> 前提チェック"
for bin in virsh cloud-localds; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done
virsh pool-info "$IMAGES_POOL" >/dev/null
virsh pool-info "$SEEDS_POOL" >/dev/null
virsh net-info default >/dev/null
[ -r "$SSH_PUBKEY_PATH" ] || { echo "pubkey not found: $SSH_PUBKEY_PATH" >&2; exit 1; }

# 前回異常終了時の残骸があれば削除。
virsh vol-delete --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" >/dev/null 2>&1 || true
virsh vol-delete --pool "$SEEDS_POOL" "$TEMP_SEED_VOL" >/dev/null 2>&1 || true

echo "==> base imageをvol-cloneでビルド用ディスクに複製: $BASE_IMAGE_NAME -> $TEMP_DISK_VOL"
virsh pool-refresh "$IMAGES_POOL" >/dev/null
virsh vol-clone --pool "$IMAGES_POOL" "$BASE_IMAGE_NAME" "$TEMP_DISK_VOL"

echo "==> ビルド用ディスクを ${BUILD_DISK_SIZE} へ拡張"
# パーティションとファイルシステムの拡張はゲスト側のcloud-init growpartが起動時に行う。
virsh vol-resize --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" "$BUILD_DISK_SIZE"

echo "==> cloud-init user-data/meta-data を生成"
b64() { base64 -w0 "$1"; }

cat > "$WORKDIR/meta-data" <<EOF
instance-id: iid-minivps-web-golden-build-001
local-hostname: minivps-web-build
EOF

# apache2の設定は defer: true でパッケージ導入後・runcmd前に書く。
# cloud-initのwrite_filesは既定でパッケージ導入前に走るため、先に書くと
# /etc/apache2 が未作成の状態でファイルだけが置かれ、apache2導入時にaptが
# ディレクトリ衝突で失敗する。nftables.confは従来どおり導入前に書く。
cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: minivps-web-build
users:
  - name: ubuntu
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_PUBKEY_PATH")
package_update: true
packages:
  - nftables
  - apache2
write_files:
  - path: /etc/nftables.conf
    permissions: '0640'
    encoding: b64
    content: $(b64 "$REPO_ROOT/image/etc/nftables.conf")
  - path: /etc/apache2/conf-available/zz-minivps-hardening.conf
    permissions: '0644'
    encoding: b64
    defer: true
    content: $(b64 "$REPO_ROOT/image/etc/apache2/conf-available/zz-minivps-hardening.conf")
  - path: /root/golden-finalize.sh
    permissions: '0700'
    content: |
      #!/bin/bash
      set -euxo pipefail
      a2enconf zz-minivps-hardening
      systemctl enable nftables.service apache2.service
      # --machine-id は比較的新しいcloud-init(24.1+)のみ対応。未対応版へのフォールバック。
      cloud-init clean --logs --machine-id || cloud-init clean --logs
      truncate -s 0 /etc/machine-id
      rm -f /root/golden-finalize.sh
      # poweroffは必ずこの関数の最後の行にする。cloud-init cleanで状態を消した後に
      # power_state: モジュール等の後続処理を動かすと、消した状態を前提にした
      # 処理が失敗しシャットダウンがスケジュールされないことがあるため、
      # power_state: ディレクティブは使わずここで直接呼ぶ。
      systemctl poweroff --no-block
runcmd:
  - /root/golden-finalize.sh
EOF

cloud-localds "$WORKDIR/seed.iso" "$WORKDIR/user-data" "$WORKDIR/meta-data"

echo "==> seed ISOをvolume APIで${SEEDS_POOL}プールへアップロード"
SEED_SIZE_BYTES=$(stat -c%s "$WORKDIR/seed.iso")
cat > "$WORKDIR/seed-vol.xml" <<EOF
<volume>
  <name>$TEMP_SEED_VOL</name>
  <capacity unit='bytes'>$SEED_SIZE_BYTES</capacity>
  <target>
    <format type='raw'/>
  </target>
</volume>
EOF
virsh vol-create "$SEEDS_POOL" "$WORKDIR/seed-vol.xml"
virsh vol-upload --pool "$SEEDS_POOL" --vol "$TEMP_SEED_VOL" --file "$WORKDIR/seed.iso" --sparse

echo "==> ビルドVMを起動(transient): $BUILD_VM_NAME"
TEMP_DISK_PATH="$(virsh vol-path --pool "$IMAGES_POOL" "$TEMP_DISK_VOL")"
TEMP_SEED_PATH="$(virsh vol-path --pool "$SEEDS_POOL" "$TEMP_SEED_VOL")"
cat > "$WORKDIR/domain.xml" <<EOF
<domain type='kvm'>
  <name>$BUILD_VM_NAME</name>
  <memory unit='KiB'>$((BUILD_MEMORY_MB * 1024))</memory>
  <vcpu>$BUILD_VCPUS</vcpu>
  <cpu mode='host-model'/>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader secure='no'/>
    <boot dev='hd'/>
  </os>
  <features><acpi/></features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source file='$TEMP_DISK_PATH'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$TEMP_SEED_PATH'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
EOF

virsh create "$WORKDIR/domain.xml"

echo "==> cloud-init完了を待機(最大${WAIT_TIMEOUT_SEC}秒)"
# on_poweroff=destroy のtransientドメインは、poweroff発生時に「shut off」状態を
# 経由せず即座にlibvirtのドメイン一覧から消える。
elapsed=0
while virsh domstate "$BUILD_VM_NAME" >/dev/null 2>&1; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
    echo "タイムアウト。virsh console $BUILD_VM_NAME で調査してください" >&2
    exit 1
  fi
done
echo "ビルドVMの処理が完了しました(${elapsed}秒)"

echo "==> 完成したディスクを ${GOLDEN_IMAGE_NAME} として確定(vol-clone)"
virsh vol-clone --pool "$IMAGES_POOL" "$TEMP_DISK_VOL" "$GOLDEN_IMAGE_NAME"
virsh pool-refresh "$IMAGES_POOL" >/dev/null

echo "==> 完成: base_image: $GOLDEN_IMAGE_NAME としてspecから参照可能"
