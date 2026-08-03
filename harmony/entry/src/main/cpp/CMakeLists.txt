cmake_minimum_required(VERSION 3.5)

set(OHOS_STL c++_static CACHE STRING "" FORCE)

project(entry C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(HARMONY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../..")
set(ABI_INCLUDE_DIR "${HARMONY_ROOT}/core/abi/include")
set(ABI_SOURCE "${HARMONY_ROOT}/core/abi/src/cmfa_contract.cpp")
set(CORE_LIBRARY_PATH "${HARMONY_ROOT}/artifacts/libcmfa_mihomo.so")

if(NOT EXISTS "${CORE_LIBRARY_PATH}")
  message(FATAL_ERROR "Missing real core artifact: ${CORE_LIBRARY_PATH}")
endif()

add_library(cmfa_mihomo SHARED IMPORTED GLOBAL)
set_target_properties(cmfa_mihomo PROPERTIES IMPORTED_LOCATION "${CORE_LIBRARY_PATH}")

add_library(entry SHARED
  "${ABI_SOURCE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/cmfa_mihomo_backend.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/napi_environment.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/js_codec.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/js_errors.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/js_async.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/js_events.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/js_core_module.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/addon_init.cpp"
)

set_source_files_properties(
  "${ABI_SOURCE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/cmfa_mihomo_backend.cpp"
  PROPERTIES COMPILE_DEFINITIONS "CMFA_INTERNAL_BACKEND_API=1"
)

target_include_directories(entry PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${ABI_INCLUDE_DIR}"
)

target_compile_options(entry PRIVATE
  -Wall
  -Wextra
  -Werror
  -Wno-unused-command-line-argument
  -fvisibility=hidden
)

target_link_libraries(entry PRIVATE
  cmfa_mihomo
  libace_napi.z.so
  libhilog_ndk.z.so
)
