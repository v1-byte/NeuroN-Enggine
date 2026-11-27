#!/usr/bin/env bash
# Menyiapkan source native: llama.cpp (dan opsional Vulkan-Headers). Jalankan dari mana saja.
#
# Pemakaian:
#   scripts/setup_native.sh [--tag <tag-llama.cpp>] [--vulkan]
#
# Skrip ini aman dijalankan berulang kali (idempoten) dan menangani tiga keadaan:
#   1. Repo git dengan .gitmodules (kasus normal)     -> git submodule update --init
#   2. Repo git tanpa submodule terdaftar             -> git submodule add
#   3. Bukan repo git (mis. zip tanpa .git)           -> git clone langsung ke folder tujuan
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPP="$ROOT/engine/src/main/cpp"
LLAMA_DIR="$CPP/llama.cpp"
LLAMA_URL="https://github.com/ggml-org/llama.cpp"
VK_DIR="$CPP/Vulkan-Headers"
VK_URL="https://github.com/KhronosGroup/Vulkan-Headers"

TAG=""
WITH_VULKAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vulkan) WITH_VULKAN=1 ;;
    --tag)
      shift
      [ $# -gt 0 ] || { echo "Opsi --tag butuh nilai, mis. --tag b6000" >&2; exit 2; }
      TAG="$1" ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Opsi tidak dikenal: $1 (lihat --help)" >&2; exit 2 ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || { echo "git tidak ditemukan. Pasang git dulu." >&2; exit 1; }

in_git_repo() { git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
is_ready() { [ -f "$1" ]; }

# $1=path relatif dari ROOT, $2=url, $3=berkas penanda bahwa isinya lengkap
ensure_source() {
  local rel="$1" url="$2" marker="$3" abs="$ROOT/$1"
  if is_ready "$abs/$marker"; then
    echo "[ok] $rel sudah ada."
    return 0
  fi
  if in_git_repo; then
    if git -C "$ROOT" config -f .gitmodules --get-regexp "submodule\\..*\\.path" 2>/dev/null | grep -q " $rel\$"; then
      echo "[..] Mengambil submodule $rel"
      git -C "$ROOT" submodule update --init --depth 1 -- "$rel"
    else
      echo "[..] Mendaftarkan submodule $rel"
      git -C "$ROOT" submodule add "$url" "$rel"
    fi
  else
    echo "[..] Bukan repo git; meng-clone $url ke $rel"
    rm -rf "$abs"
    git clone --depth 1 "$url" "$abs"
  fi
  is_ready "$abs/$marker" || { echo "Gagal: $rel/$marker tidak ada setelah pengambilan. Periksa koneksi lalu ulangi." >&2; exit 1; }
}

ensure_source "engine/src/main/cpp/llama.cpp" "$LLAMA_URL" "CMakeLists.txt"

if [ -n "$TAG" ]; then
  echo "[..] Mengunci llama.cpp ke tag $TAG"
  git -C "$LLAMA_DIR" fetch --depth 1 origin tag "$TAG" 2>/dev/null || git -C "$LLAMA_DIR" fetch --tags origin
  git -C "$LLAMA_DIR" checkout --quiet "$TAG"
  if in_git_repo; then git -C "$ROOT" add engine/src/main/cpp/llama.cpp 2>/dev/null || true; fi
else
  echo "[!!] llama.cpp belum dikunci ke tag rilis. API-nya berubah cepat; disarankan: $0 --tag <tag>"
fi

[ -f "$LLAMA_DIR/include/llama.h" ] || { echo "llama.cpp/include/llama.h tidak ditemukan; checkout tidak lengkap." >&2; exit 1; }
echo "[ok] llama.cpp @ $(git -C "$LLAMA_DIR" describe --tags --always 2>/dev/null || echo tidak-diketahui)"

if [ "$WITH_VULKAN" = 1 ]; then
  ensure_source "engine/src/main/cpp/Vulkan-Headers" "$VK_URL" "include/vulkan/vulkan.hpp"
fi

echo "Selesai. Lanjut: ./gradlew :engine:assembleDebug -PwithNative$( [ "$WITH_VULKAN" = 1 ] && echo ' -PwithVulkan')"
