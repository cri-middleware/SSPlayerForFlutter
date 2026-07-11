# ssplayer_flutter — Windows FFI plugin.
#
# Bundles the PREBUILT dynamic Brain (ssruntime.dll) produced by
# `scripts/build-runtime.ps1 platform=windows` under
# ../native/libs/windows/<arch>/. Flutter copies files listed in
# <plugin>_bundled_libraries next to the app .exe, from where
# DynamicLibrary.open('ssruntime.dll') loads it.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "ssplayer_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|arm64")
  set(SS_ARCH "arm64")
else()
  set(SS_ARCH "x86_64")
endif()

set(SS_RUNTIME_LIB
    "${CMAKE_CURRENT_SOURCE_DIR}/../native/libs/windows/${SS_ARCH}/ssruntime.dll")

add_library(${PROJECT_NAME} INTERFACE)

set(ssplayer_flutter_bundled_libraries
    "${SS_RUNTIME_LIB}"
    PARENT_SCOPE)
