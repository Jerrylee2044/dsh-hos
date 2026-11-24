cmake_minimum_required(VERSION 3.5.0)
project(dsh_host LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(dsh_host SHARED napi_init.cpp)
target_compile_definitions(dsh_host PRIVATE _GNU_SOURCE)
set_target_properties(dsh_host PROPERTIES OUTPUT_NAME dsh_host)
target_link_libraries(dsh_host PUBLIC libace_napi.z.so libhilog_ndk.z.so z)
