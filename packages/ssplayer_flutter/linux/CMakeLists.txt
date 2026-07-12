# ssplayer_flutter — Linux FFI plugin.
#
# Bundles the PREBUILT dynamic Brain (libssruntime.so) produced by
# `scripts/build-runtime.sh platform=linux` under ../native/libs/linux/<arch>/.
# Flutter copies files listed in <plugin>_bundled_libraries into the app's
# lib/ dir, from where DynamicLibrary.open('libssruntime.so') loads it.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "ssplayer_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

# Detect the host arch subfolder produced by build-runtime.sh (x86_64 / aarch64).
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
  set(SS_ARCH "aarch64")
else()
  set(SS_ARCH "x86_64")
endif()

set(SS_RUNTIME_LIB
    "${CMAKE_CURRENT_SOURCE_DIR}/../native/libs/linux/${SS_ARCH}/libssruntime.so")

# This plugin has no compiled platform code; expose an empty target so the
# Flutter tooling has something to reference.
add_library(${PROJECT_NAME} INTERFACE)

# Ship the prebuilt Brain alongside the app.
set(ssplayer_flutter_bundled_libraries
    "${SS_RUNTIME_LIB}"
    PARENT_SCOPE)
