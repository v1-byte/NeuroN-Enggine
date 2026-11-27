cmake_minimum_required(VERSION 3.22)
project(neuron_llama LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)

# Build Debug bawaan Gradle = -O0: inferensi bisa 10-50x lebih lambat. Paksa optimasi di semua varian.
set(CMAKE_C_FLAGS_DEBUG   "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-O3 -DNDEBUG")

if(NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/CMakeLists.txt)
  message(FATAL_ERROR "llama.cpp belum ada. Jalankan scripts/setup_native.sh (lihat docs/NATIVE.md)")
endif()

# Build llama.cpp sebagai pustaka statis, tanpa tool/contoh/server/curl.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)      # wajib OFF saat cross-compile
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
# Aman untuk hampir semua arm64 modern; naikkan (mis. armv8.6-a+i8mm) bila target HP flagship saja.
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod" CACHE STRING "" FORCE)

# Vulkan (GPU) opsional: ./gradlew assembleDebug -PwithNative -PwithVulkan  (lihat docs/NATIVE.md)
option(NEURON_VULKAN "Aktifkan backend Vulkan" OFF)
if(NEURON_VULKAN)
  set(VK_HEADERS ${CMAKE_CURRENT_SOURCE_DIR}/Vulkan-Headers)
  if(NOT EXISTS ${VK_HEADERS}/include/vulkan/vulkan.hpp)
    message(FATAL_ERROR "Vulkan-Headers belum ada. Jalankan scripts/setup_native.sh (lihat docs/NATIVE.md)")
  endif()
  # glslc ada di NDK: <ndk>/shader-tools/<host>/glslc
  find_program(NEURON_GLSLC glslc PATHS
    ${CMAKE_ANDROID_NDK}/shader-tools/linux-x86_64
    ${CMAKE_ANDROID_NDK}/shader-tools/darwin-x86_64
    ${CMAKE_ANDROID_NDK}/shader-tools/windows-x86_64
    NO_DEFAULT_PATH)
  find_library(NEURON_VULKAN_LIB vulkan)
  if(NOT NEURON_GLSLC OR NOT NEURON_VULKAN_LIB)
    message(FATAL_ERROR "glslc / libvulkan tidak ditemukan di NDK (butuh NDK r26+, minSdk >= 26)")
  endif()
  message(STATUS "Vulkan: glslc=${NEURON_GLSLC} lib=${NEURON_VULKAN_LIB}")
  set(GGML_VULKAN ON CACHE BOOL "" FORCE)
  set(GGML_VULKAN_RUN_TESTS OFF CACHE BOOL "" FORCE)
  set(Vulkan_INCLUDE_DIR ${VK_HEADERS}/include CACHE PATH "" FORCE)
  set(Vulkan_LIBRARY ${NEURON_VULKAN_LIB} CACHE FILEPATH "" FORCE)
  set(Vulkan_GLSLC_EXECUTABLE ${NEURON_GLSLC} CACHE FILEPATH "" FORCE)
  list(APPEND NEURON_EXTRA_DEFS NEURON_HAS_VULKAN)
endif()

add_subdirectory(llama.cpp)

# Deteksi versi API dari llama.h supaya tidak perlu mengatur define manual.
file(READ ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/include/llama.h NEURON_LLAMA_H)
set(NEURON_DEFS "")
string(FIND "${NEURON_LLAMA_H}" "flash_attn_type" _p1)
if(_p1 EQUAL -1)
  list(APPEND NEURON_DEFS NEURON_OLD_FLASH_API)
endif()
string(FIND "${NEURON_LLAMA_H}" "llama_memory_clear" _p2)
if(_p2 EQUAL -1)
  list(APPEND NEURON_DEFS NEURON_OLD_KV_API)
endif()
string(FIND "${NEURON_LLAMA_H}" "llama_set_adapters_lora" _p3)
if(NOT _p3 EQUAL -1)
  list(APPEND NEURON_DEFS NEURON_NEW_LORA_API)
endif()
message(STATUS "NeuroN API defs: ${NEURON_DEFS}")

add_library(neuron_llama SHARED neuron_llama.cpp)
target_compile_definitions(neuron_llama PRIVATE ${NEURON_DEFS} ${NEURON_EXTRA_DEFS})
target_link_libraries(neuron_llama PRIVATE llama android log)
# Android 15+ (halaman memori 16 KB)
target_link_options(neuron_llama PRIVATE -Wl,-z,max-page-size=16384)
