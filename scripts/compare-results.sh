#!/usr/bin/env bash
#
# compare-results.sh — Perbandingan side-by-side hybrid vs vm-only
#
# Membaca results/vmonly/ dan results/hybrid/ (jika ada) lalu mencetak tabel
# perbandingan metrik kunci: total RAM, startup time, req/s, mean latency,
# failed requests.
#
# Usage: bash scripts/compare-results.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VMONLY_DIR="$PROJECT_ROOT/results/vmonly"
HYBRID_DIR="$PROJECT_ROOT/results/hybrid"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
NA="N/A"

section() { printf '\n%s========================================================%s\n' "$BLUE" "$NC"; printf '%s  %s%s\n' "$BLUE" "$1" "$NC"; printf '%s========================================================%s\n' "$BLUE" "$NC"; }

# ----------------------------------------------------------------------------
# Helper ekstraksi (semua mengembalikan N/A jika file/nilai tidak ada)
# ----------------------------------------------------------------------------

# RAM total. vmonly: baris TOTAL_RAM_USED_MB di ram.txt.
# hybrid: jika ada baris TOTAL_RAM_USED_MB pakai itu; jika tidak, jumlahkan
# kolom MEM USAGE dari output `docker stats` (format: "123.4MiB / ...").
get_ram() {
  local dir="$1" scenario="$2" f
  f="$dir/ram.txt"
  [ -f "$f" ] || { echo "$NA"; return; }

  # 1) baris eksplisit
  local total
  total=$(grep -E '^TOTAL_RAM_USED_MB=' "$f" | tail -n1 | cut -d= -f2)
  if [[ "$total" =~ ^[0-9]+$ ]]; then echo "$total"; return; fi

  if [ "$scenario" = "hybrid" ]; then
    # jumlahkan MEM USAGE docker stats: ambil angka sebelum "MiB"/"GiB" pada
    # token tepat sebelum "/". Konversi GiB->MiB.
    local sum
    sum=$(awk '
      /[0-9.]+ *[MG]iB *\/ / {
        line=$0
        # cari pola "<num>MiB / " atau "<num>GiB / "
        if (match(line, /([0-9]+\.?[0-9]*)MiB *\//, m))      { s+=m[1] }
        else if (match(line, /([0-9]+\.?[0-9]*)GiB *\//, m)) { s+=m[1]*1024 }
      }
      END { if (s>0) printf "%d", s }
    ' "$f" 2>/dev/null)
    [[ "$sum" =~ ^[0-9]+$ ]] && { echo "$sum"; return; }
  fi
  echo "$NA"
}

# Startup elapsed (detik) dari startup.txt baris "Elapsed (...): NNs"
get_startup() {
  local f="$1/startup.txt" v
  [ -f "$f" ] || { echo "$NA"; return; }
  v=$(grep -iE 'Elapsed' "$f" | grep -oE '[0-9]+s' | head -n1 | tr -d 's')
  [[ "$v" =~ ^[0-9]+$ ]] && echo "${v}" || echo "$NA"
}

# Requests/sec dari ab.txt
get_rps() {
  local f="$1/ab.txt" v
  [ -f "$f" ] || { echo "$NA"; return; }
  v=$(grep -i 'Requests per second' "$f" | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  echo "${v:-$NA}"
}

# Mean latency (ms) dari ab.txt — "Time per request" pertama (across all concurrent)
get_mean() {
  local f="$1/ab.txt" v
  [ -f "$f" ] || { echo "$NA"; return; }
  v=$(grep -i 'Time per request' "$f" | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  echo "${v:-$NA}"
}

# Failed requests dari ab.txt
get_failed() {
  local f="$1/ab.txt" v
  [ -f "$f" ] || { echo "$NA"; return; }
  v=$(grep -i 'Failed requests' "$f" | head -n1 | grep -oE '[0-9]+' | head -n1)
  echo "${v:-$NA}"
}

# ----------------------------------------------------------------------------
section "PERBANDINGAN: HYBRID vs VM-ONLY"

[ -d "$VMONLY_DIR" ] || printf '%s[WARN]%s %s tidak ditemukan.\n' "$YELLOW" "$NC" "$VMONLY_DIR"
if [ ! -d "$HYBRID_DIR" ]; then
  printf '%s[WARN]%s %s tidak ditemukan — kolom hybrid akan N/A.\n' "$YELLOW" "$NC" "$HYBRID_DIR"
fi

V_RAM=$(get_ram "$VMONLY_DIR" vmonly)
H_RAM=$(get_ram "$HYBRID_DIR" hybrid)
V_START=$(get_startup "$VMONLY_DIR")
H_START=$(get_startup "$HYBRID_DIR")
V_RPS=$(get_rps "$VMONLY_DIR")
H_RPS=$(get_rps "$HYBRID_DIR")
V_MEAN=$(get_mean "$VMONLY_DIR")
H_MEAN=$(get_mean "$HYBRID_DIR")
V_FAIL=$(get_failed "$VMONLY_DIR")
H_FAIL=$(get_failed "$HYBRID_DIR")

# ----------------------------------------------------------------------------
# Tabel
# ----------------------------------------------------------------------------
printf '\n'
printf '%-26s | %-14s | %-14s\n' "Metrik" "HYBRID" "VM-ONLY"
printf -- '---------------------------+----------------+---------------\n'
printf '%-26s | %-14s | %-14s\n' "Total RAM used (MB)"   "$H_RAM"   "$V_RAM"
printf '%-26s | %-14s | %-14s\n' "Startup elapsed (s)*"  "$H_START" "$V_START"
printf '%-26s | %-14s | %-14s\n' "Requests / sec"        "$H_RPS"   "$V_RPS"
printf '%-26s | %-14s | %-14s\n' "Mean latency (ms)"     "$H_MEAN"  "$V_MEAN"
printf '%-26s | %-14s | %-14s\n' "Failed requests"       "$H_FAIL"  "$V_FAIL"
printf '\n'
printf '%s* Startup elapsed = waktu script -> first HTTP 200, BELUM termasuk%s\n' "$YELLOW" "$NC"
printf '%s  durasi terraform apply (ukur manual).%s\n' "$YELLOW" "$NC"

# ----------------------------------------------------------------------------
# Interpretasi singkat (delta RAM)
# ----------------------------------------------------------------------------
if [[ "$V_RAM" =~ ^[0-9]+$ && "$H_RAM" =~ ^[0-9]+$ ]]; then
  delta=$(( V_RAM - H_RAM ))
  printf '\n%s== Catatan ==%s\n' "$GREEN" "$NC"
  if [ "$delta" -gt 0 ]; then
    printf '  VM-only memakai %d MB LEBIH BANYAK RAM dari hybrid\n' "$delta"
    printf '  (3 OS guest terpisah vs 1 OS guest + kontainer ringan).\n'
  elif [ "$delta" -lt 0 ]; then
    printf '  VM-only memakai %d MB LEBIH SEDIKIT RAM dari hybrid.\n' "$(( -delta ))"
  else
    printf '  RAM kedua skenario setara.\n'
  fi
fi
printf '\n'
