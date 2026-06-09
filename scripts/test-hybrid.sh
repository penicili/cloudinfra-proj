#!/usr/bin/env bash
#
# test-hybrid.sh — Pengujian skenario HYBRID (Bab V)
#
# Skenario hybrid: SATU EC2 menjalankan 3 kontainer (app, nginx, redis) via
# docker-compose. Bandingkan dengan vm-only (3 VM terpisah).
#
# Menjalankan tes fungsional, benchmark (ab), pemindaian keamanan (nmap),
# pengukuran RAM (docker stats via SSH), dan startup time.
#
# Jalankan SETELAH `terraform -chdir=terraform/hybrid apply` selesai.
#
# Usage:
#   bash scripts/test-hybrid.sh
#   KEY_PATH=~/.ssh/key.pem bash scripts/test-hybrid.sh
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Konfigurasi
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform/hybrid"
RESULTS_DIR="$PROJECT_ROOT/results/hybrid"

KEY_PATH="${KEY_PATH:-$HOME/.ssh/id_rsa}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# Parameter Apache Bench — HARUS sama dengan skenario vm-only (apple-to-apple)
AB_REQUESTS=1000
AB_CONCURRENCY=10

WAIT_SECONDS=90

SCRIPT_START_EPOCH=$(date +%s)

# ----------------------------------------------------------------------------
# Helper
# ----------------------------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

section() { printf '\n%s========================================================%s\n' "$BLUE" "$NC"; printf '%s  %s%s\n' "$BLUE" "$1" "$NC"; printf '%s========================================================%s\n' "$BLUE" "$NC"; }
info()    { printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$1"; }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; }
err()     { printf '%s[ERR ]%s %s\n' "$RED" "$NC" "$1" >&2; }
die()     { err "$1"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Tool '$1' tidak ditemukan di PATH. Install dulu."; }

# ----------------------------------------------------------------------------
# Pra-syarat
# ----------------------------------------------------------------------------
section "PRA-SYARAT"
need terraform
need curl
need ab
need nmap
need ssh

[ -d "$TF_DIR" ] || die "Direktori terraform tidak ditemukan: $TF_DIR"
if [ ! -f "$KEY_PATH" ]; then
  warn "SSH key tidak ditemukan di '$KEY_PATH' — tes RAM (docker stats) akan dilewati."
  warn "Set dengan: KEY_PATH=~/.ssh/key.pem bash scripts/test-hybrid.sh"
  KEY_PATH=""
fi
info "Tools OK. KEY_PATH=${KEY_PATH:-<none>}"

# ----------------------------------------------------------------------------
# 1. Baca output terraform
# ----------------------------------------------------------------------------
section "MEMBACA OUTPUT TERRAFORM (terraform/hybrid)"

PUBLIC_IP=$(terraform -chdir="$TF_DIR" output -raw public_ip 2>/dev/null) \
  || die "Gagal baca output 'public_ip'. Sudah 'terraform apply'?"
[ -n "$PUBLIC_IP" ] || die "public_ip kosong."
info "EC2 (public): $PUBLIC_IP"

# ----------------------------------------------------------------------------
# 2. Siapkan direktori hasil
# ----------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR" || die "Gagal membuat $RESULTS_DIR"
info "Hasil disimpan ke: $RESULTS_DIR"

# ----------------------------------------------------------------------------
# 3. Tunggu user_data selesai (countdown)
# ----------------------------------------------------------------------------
section "MENUNGGU USER_DATA (${WAIT_SECONDS}s)"
for ((i=WAIT_SECONDS; i>0; i--)); do
  printf '\r  Menunggu provisioning selesai... %3ds  ' "$i"
  sleep 1
done
printf '\r  Menunggu provisioning selesai... selesai.   \n'

# ----------------------------------------------------------------------------
# 4a. STARTUP TIME
# ----------------------------------------------------------------------------
section "STARTUP TIME"
STARTUP_FILE="$RESULTS_DIR/startup.txt"
BASE_URL="http://$PUBLIC_IP"

info "Polling $BASE_URL/ sampai HTTP 200 (maks 120 percobaan @2s)..."
FIRST_200_EPOCH=""
for ((attempt=1; attempt<=120; attempt++)); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/" || echo "000")
  if [ "$code" = "200" ]; then
    FIRST_200_EPOCH=$(date +%s)
    info "HTTP 200 diterima pada percobaan ke-$attempt."
    break
  fi
  printf '\r  Percobaan %3d — status: %s   ' "$attempt" "$code"
  sleep 2
done
printf '\n'

{
  echo "=== STARTUP TIME (HYBRID) ==="
  echo "Script start : $(date -d "@$SCRIPT_START_EPOCH" 2>/dev/null || date -r "$SCRIPT_START_EPOCH")"
  if [ -n "$FIRST_200_EPOCH" ]; then
    elapsed=$(( FIRST_200_EPOCH - SCRIPT_START_EPOCH ))
    echo "First HTTP 200: $(date -d "@$FIRST_200_EPOCH" 2>/dev/null || date -r "$FIRST_200_EPOCH")"
    echo "Elapsed (script start -> first 200): ${elapsed}s"
    echo "  catatan: ${WAIT_SECONDS}s di antaranya adalah wait countdown."
  else
    echo "First HTTP 200: TIDAK PERNAH (timeout)"
    echo "Elapsed: N/A"
  fi
  echo
  echo "CATATAN PENTING:"
  echo "  Startup time TOTAL = durasi 'terraform apply' (ukur manual dgn stopwatch)"
  echo "  + elapsed di atas. terraform apply tidak diukur oleh script ini."
} > "$STARTUP_FILE"
cat "$STARTUP_FILE"

[ -n "$FIRST_200_EPOCH" ] || warn "App tidak pernah mengembalikan 200 — tes berikutnya mungkin gagal."

# ----------------------------------------------------------------------------
# 4b. FUNCTIONAL
# ----------------------------------------------------------------------------
section "TES FUNGSIONAL"
FUNC_FILE="$RESULTS_DIR/functional.txt"
: > "$FUNC_FILE"

func_pass_shorten="FAIL"; func_pass_redirect="FAIL"; func_pass_info="FAIL"; func_pass_404="FAIL"

{
  echo "=== TES FUNGSIONAL (HYBRID) — $(date) ==="
  echo "Base URL: $BASE_URL"
  echo
} >> "$FUNC_FILE"

info "POST /shorten ..."
SHORTEN_RESP=$(curl -s -w '\n__HTTP__%{http_code}' -X POST "$BASE_URL/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url": "https://google.com"}' --max-time 15)
SHORTEN_CODE=$(printf '%s' "$SHORTEN_RESP" | sed -n 's/.*__HTTP__//p')
SHORTEN_BODY=$(printf '%s' "$SHORTEN_RESP" | sed 's/__HTTP__[0-9]*$//')

{
  echo "--- [1] POST /shorten {\"url\":\"https://google.com\"} ---"
  echo "HTTP status: $SHORTEN_CODE"
  echo "Response body:"
  echo "$SHORTEN_BODY"
  echo
} >> "$FUNC_FILE"

CODE=$(printf '%s' "$SHORTEN_BODY" | grep -oE '[A-Za-z0-9]{6}' | tail -n1)
if [ "$SHORTEN_CODE" = "201" ] && [ -n "$CODE" ]; then
  func_pass_shorten="PASS"; info "  -> code = $CODE (HTTP $SHORTEN_CODE)"
else
  warn "  -> gagal mendapat code (HTTP $SHORTEN_CODE)"
fi

if [ -n "$CODE" ]; then
  info "GET /$CODE (follow redirect) ..."
  REDIR_HEADERS=$(curl -s -D - -o /dev/null --max-time 15 "$BASE_URL/$CODE")
  REDIR_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/$CODE")
  FINAL_URL=$(curl -s -L -o /dev/null -w '%{url_effective}' --max-time 20 "$BASE_URL/$CODE")
  {
    echo "--- [2] GET /$CODE (redirect) ---"
    echo "Status awal: $REDIR_STATUS (harapan 301)"
    echo "Final URL (setelah -L): $FINAL_URL"
    echo "Response headers:"
    echo "$REDIR_HEADERS"
    echo
  } >> "$FUNC_FILE"
  if [ "$REDIR_STATUS" = "301" ]; then
    func_pass_redirect="PASS"; info "  -> redirect 301 OK"
  else
    warn "  -> status $REDIR_STATUS (bukan 301)"
  fi

  info "GET /info/$CODE ..."
  INFO_RESP=$(curl -s -w '\n__HTTP__%{http_code}' --max-time 15 "$BASE_URL/info/$CODE")
  INFO_CODE=$(printf '%s' "$INFO_RESP" | sed -n 's/.*__HTTP__//p')
  INFO_BODY=$(printf '%s' "$INFO_RESP" | sed 's/__HTTP__[0-9]*$//')
  {
    echo "--- [3] GET /info/$CODE ---"
    echo "HTTP status: $INFO_CODE"
    echo "Response body:"
    echo "$INFO_BODY"
    echo
  } >> "$FUNC_FILE"
  if [ "$INFO_CODE" = "200" ]; then
    func_pass_info="PASS"; info "  -> info 200 OK"
  else
    warn "  -> status $INFO_CODE"
  fi
else
  {
    echo "--- [2][3] DILEWATI: tidak ada code dari /shorten ---"
    echo
  } >> "$FUNC_FILE"
  warn "GET /<code> & /info dilewati (tidak ada code)."
fi

info "GET /zzzzzz (invalid, harap 404) ..."
INVALID_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/zzzzzz")
{
  echo "--- [4] GET /zzzzzz (invalid code) ---"
  echo "HTTP status: $INVALID_CODE (harapan 404)"
  echo
} >> "$FUNC_FILE"
if [ "$INVALID_CODE" = "404" ]; then
  func_pass_404="PASS"; info "  -> 404 OK"
else
  warn "  -> status $INVALID_CODE (bukan 404)"
fi

# ----------------------------------------------------------------------------
# 4c. APACHE BENCH
# ----------------------------------------------------------------------------
section "APACHE BENCH (ab -n $AB_REQUESTS -c $AB_CONCURRENCY)"
AB_FILE="$RESULTS_DIR/ab.txt"
info "Menjalankan ab terhadap $BASE_URL/ ..."
{
  echo "=== APACHE BENCH (HYBRID) — $(date) ==="
  echo "Command: ab -n $AB_REQUESTS -c $AB_CONCURRENCY $BASE_URL/"
  echo "(parameter identik dengan skenario vm-only untuk perbandingan apple-to-apple)"
  echo
} > "$AB_FILE"
if ab -n "$AB_REQUESTS" -c "$AB_CONCURRENCY" "$BASE_URL/" >> "$AB_FILE" 2>&1; then
  AB_RPS=$(grep -i 'Requests per second' "$AB_FILE" | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  AB_MEAN=$(grep -i 'Time per request' "$AB_FILE" | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  AB_FAILED=$(grep -i 'Failed requests' "$AB_FILE" | head -n1 | grep -oE '[0-9]+' | head -n1)
  info "  -> ${AB_RPS:-?} req/s, mean ${AB_MEAN:-?} ms, failed ${AB_FAILED:-?}"
else
  warn "ab gagal — lihat $AB_FILE"
  AB_RPS="ERR"; AB_MEAN="ERR"; AB_FAILED="ERR"
fi

# ----------------------------------------------------------------------------
# 4d. NMAP SECURITY
# ----------------------------------------------------------------------------
section "NMAP SECURITY SCAN"
NMAP_FILE="$RESULTS_DIR/nmap.txt"
info "nmap EC2 ($PUBLIC_IP) port 80,22,5000,6379 ..."
{
  echo "=== NMAP (HYBRID) — $(date) ==="
  echo
  echo "--- [EC2] $PUBLIC_IP : ports 80,22,5000,6379 ---"
  echo "Harapan: 80=open, 22=open, 5000=closed/filtered, 6379=closed/filtered"
  echo "(Flask:5000 & Redis:6379 hanya di docker bridge network, tidak di-expose ke host)"
} > "$NMAP_FILE"
nmap -p 80,22,5000,6379 "$PUBLIC_IP" >> "$NMAP_FILE" 2>&1 || warn "nmap error"

port_state() { grep -E "^$1/tcp" "$NMAP_FILE" | head -n1 | awk '{print $2}'; }
P80=$(port_state 80);   P22=$(port_state 22)
P5000=$(port_state 5000); P6379=$(port_state 6379)

# ----------------------------------------------------------------------------
# 4e. RAM USAGE (docker stats via SSH)
# ----------------------------------------------------------------------------
section "RAM USAGE (docker stats via SSH)"
RAM_FILE="$RESULTS_DIR/ram.txt"
: > "$RAM_FILE"
echo "=== RAM USAGE (HYBRID) — $(date) ===" >> "$RAM_FILE"
echo >> "$RAM_FILE"

RAM_TOTAL="N/A"
if [ -n "$KEY_PATH" ]; then
  info "SSH EC2 ($PUBLIC_IP) -> docker stats ..."
  echo "--- [EC2] docker stats (no-stream) ---" >> "$RAM_FILE"
  STATS=$(ssh $SSH_OPTS -i "$KEY_PATH" "$SSH_USER@$PUBLIC_IP" \
    "docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'" 2>>"$RAM_FILE")
  if [ -n "$STATS" ]; then
    echo "$STATS" >> "$RAM_FILE"
    echo >> "$RAM_FILE"
    # juga simpan free -m host untuk referensi
    echo "--- [EC2] free -m (host) ---" >> "$RAM_FILE"
    ssh $SSH_OPTS -i "$KEY_PATH" "$SSH_USER@$PUBLIC_IP" 'free -m' >> "$RAM_FILE" 2>>"$RAM_FILE"
    echo >> "$RAM_FILE"
    # Jumlahkan MEM USAGE kontainer (kolom "<num>MiB / ..."), GiB->MiB
    RAM_TOTAL=$(printf '%s\n' "$STATS" | awk '
      {
        if (match($0, /([0-9]+\.?[0-9]*)MiB *\//)) { s += substr($0, RSTART, RLENGTH-5) }
        else if (match($0, /([0-9]+\.?[0-9]*)GiB *\//)) { s += substr($0, RSTART, RLENGTH-5)*1024 }
      }
      END { if (s>0) printf "%d", s }')
    [[ "$RAM_TOTAL" =~ ^[0-9]+$ ]] || RAM_TOTAL="N/A"
    info "  -> total kontainer: ${RAM_TOTAL} MB"
  else
    warn "docker stats kosong / SSH gagal."
    echo "GAGAL: docker stats kosong atau SSH gagal." >> "$RAM_FILE"
  fi
else
  warn "RAM test dilewati (KEY_PATH kosong)."
  echo "DILEWATI: KEY_PATH tidak di-set." >> "$RAM_FILE"
fi

# Simpan total agar dibaca compare-results.sh
echo "TOTAL_RAM_USED_MB=$RAM_TOTAL" >> "$RAM_FILE"

# ----------------------------------------------------------------------------
# 5. SUMMARY TABLE
# ----------------------------------------------------------------------------
section "RINGKASAN HASIL (HYBRID)"

printf '\n%s== RAM (MB, docker stats) ==%s\n' "$YELLOW" "$NC"
printf '  %-22s %s\n' "Total kontainer:" "${RAM_TOTAL} MB"

printf '\n%s== Apache Bench ==%s\n' "$YELLOW" "$NC"
printf '  %-22s %s\n' "Requests/sec:"      "${AB_RPS:-?}"
printf '  %-22s %s\n' "Mean latency (ms):" "${AB_MEAN:-?}"
printf '  %-22s %s\n' "Failed requests:"   "${AB_FAILED:-?}"

printf '\n%s== Port State (EC2 %s) ==%s\n' "$YELLOW" "$PUBLIC_IP" "$NC"
printf '  %-8s %s\n' "80"   "${P80:-?}"
printf '  %-8s %s\n' "22"   "${P22:-?}"
printf '  %-8s %s\n' "5000" "${P5000:-?}  (harap closed/filtered)"
printf '  %-8s %s\n' "6379" "${P6379:-?}  (harap closed/filtered)"

printf '\n%s== Tes Fungsional ==%s\n' "$YELLOW" "$NC"
fmt() { [ "$1" = "PASS" ] && printf '%sPASS%s' "$GREEN" "$NC" || printf '%sFAIL%s' "$RED" "$NC"; }
printf '  %-22s %s\n' "POST /shorten:"      "$(fmt "$func_pass_shorten")"
printf '  %-22s %s\n' "GET /<code> (301):"  "$(fmt "$func_pass_redirect")"
printf '  %-22s %s\n' "GET /info/<code>:"   "$(fmt "$func_pass_info")"
printf '  %-22s %s\n' "GET /<invalid> 404:" "$(fmt "$func_pass_404")"

printf '\n%sSemua hasil mentah tersimpan di: %s%s\n' "$GREEN" "$RESULTS_DIR" "$NC"
printf '  functional.txt  ab.txt  nmap.txt  ram.txt  startup.txt\n'
printf '\nJalankan %sbash scripts/compare-results.sh%s untuk membandingkan dengan vm-only.\n\n' "$BLUE" "$NC"
