#!/usr/bin/env bash
# Клонирует тематические (прокси/анти-цензура) зависимости 3x-ui в Vendor/
# на точных версиях из go.mod. Псевдо-версии резолвятся в SHA коммита.
set -u
VENDOR="/Volumes/Kingston/3x-ui/Vendor"
mkdir -p "$VENDOR"
LOG="$VENDOR/_clone.log"
: > "$LOG"

# name|repo_url|ref   (ref = semver-тег ИЛИ 12-символьный SHA коммита из псевдо-версии)
ENTRIES=(
  "xray-core|https://github.com/xtls/xray-core|94ffd50060f1"
  "reality|https://github.com/xtls/reality|9234c772ba8f"
  "utls|https://github.com/refraction-networking/utls|aa6edf4b11af"
  "sing|https://github.com/sagernet/sing|v0.8.10"
  "sing-shadowsocks|https://github.com/sagernet/sing-shadowsocks|v0.2.9"
  "quic-go|https://github.com/quic-go/quic-go|v0.60.0"
  "apernet-quic-go|https://github.com/apernet/quic-go|6c6cc9bcb716"
  "qpack|https://github.com/quic-go/qpack|v0.6.0"
  "wireguard-go|https://github.com/WireGuard/wireguard-go|ecfc5a8d5446"
  "wireguard-windows|https://github.com/WireGuard/wireguard-windows|v1.0.1"
  "wintun|https://git.zx2c4.com/wintun|__default__"
  "miekg-dns|https://github.com/miekg/dns|v1.1.72"
  "go-proxyproto|https://github.com/pires/go-proxyproto|v0.12.0"
  "blake3|https://github.com/lukechampine/blake3|v1.4.1"
  "circl|https://github.com/cloudflare/circl|v1.6.3"
  "telego|https://github.com/mymmrac/telego|v1.10.0"
)

log(){ echo "$@" | tee -a "$LOG"; }

clone_one(){
  local name="$1" url="$2" ref="$3" dir="$VENDOR/$1"
  rm -rf "$dir"
  # 1) default branch явно запрошен
  if [ "$ref" = "__default__" ]; then
    if git clone --depth 1 "$url" "$dir" >>"$LOG" 2>&1; then
      log "OK   $name  (default branch)"; return; fi
    log "FAIL $name  ($url) default-clone failed"; return
  fi
  # 2) пробуем как тег/ветку
  if git clone --depth 1 --branch "$ref" "$url" "$dir" >>"$LOG" 2>&1; then
    log "OK   $name  (tag $ref)"; return; fi
  # 3) пробуем как SHA коммита (псевдо-версия)
  rm -rf "$dir"; mkdir -p "$dir"
  if ( cd "$dir" && git init -q && git remote add origin "$url" \
        && git fetch --depth 1 origin "$ref" >>"$LOG" 2>&1 \
        && git checkout -q FETCH_HEAD ); then
    log "OK   $name  (commit $ref)"; return; fi
  # 4) откат на default branch
  rm -rf "$dir"
  if git clone --depth 1 "$url" "$dir" >>"$LOG" 2>&1; then
    log "WARN $name  (ref $ref не найден → default branch)"; return; fi
  log "FAIL $name  ($url ref=$ref) все попытки провалились"
}

for e in "${ENTRIES[@]}"; do
  IFS='|' read -r name url ref <<< "$e"
  log "--- $name @ $ref ---"
  clone_one "$name" "$url" "$ref"
done

log "=== ИТОГ ==="
du -sh "$VENDOR"/*/ 2>/dev/null | tee -a "$LOG"
log "=== Размер Vendor: $(du -sh "$VENDOR" | cut -f1) ==="
echo "__VENDOR_CLONE_DONE__"
