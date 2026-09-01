cmake_minimum_required(VERSION 3.5)

set(OHOS_STL c++_static CACHE STRING "" FORCE)

project(probeentry C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

add_library(probeentry SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/probe_native_core.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/probe_native_napi.cpp"
)

target_compile_options(probeentry PRIVATE
  -Wall
  -Wextra
  -Werror
  -fvisibility=hidden
)

if(CMAKE_SYSTEM_NAME STREQUAL "OHOS" AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  target_compile_options(probeentry PRIVATE -Wno-unused-command-line-argument)
endif()

target_link_options(probeentry PRIVATE
  -Wl,--exclude-libs,ALL
)

target_link_libraries(probeentry PRIVATE
  libace_napi.z.so
)
