#!/usr/bin/env bash
# Menambahkan llama.cpp sebagai submodule. Jalankan dari root repo.
set -e
git submodule add https://github.com/ggml-org/llama.cpp engine/src/main/cpp/llama.cpp
# Disarankan mengunci ke satu tag rilis agar API stabil, mis.:
#   cd engine/src/main/cpp/llama.cpp && git checkout <tag> && cd - && git add engine/src/main/cpp/llama.cpp
# Opsional (Vulkan/GPU): header Vulkan-Hpp yang cukup baru (header bawaan NDK sering terlalu lama)
if [ "$1" = "--vulkan" ]; then
  git submodule add https://github.com/KhronosGroup/Vulkan-Headers engine/src/main/cpp/Vulkan-Headers
fi
echo "Selesai. Lanjut: tambahkan 'withNative=true' ke gradle.properties, lalu build."
