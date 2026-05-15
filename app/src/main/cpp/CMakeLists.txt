cmake_minimum_required(VERSION 3.22.1)

project("evcam_gles_compositor")

find_program(ZIG_EXECUTABLE zig REQUIRED)
set(EVCAM_ZIG_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../zig/evcam_gles_compositor.zig")
set(EVCAM_ZIG_BUILD "${CMAKE_CURRENT_SOURCE_DIR}/../zig/build.zig")
set(EVCAM_ZIG_C_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/../zig/evcam_c.h")
set(EVCAM_ZIG_LIBC_FILE "${CMAKE_CURRENT_BINARY_DIR}/zig_android_libc.txt")
file(GLOB EVCAM_ZIG_DEPS CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/../zig/*.zig"
        "${EVCAM_ZIG_C_HEADER}")

set(EVCAM_ZIG_ANCHOR "${CMAKE_CURRENT_BINARY_DIR}/evcam_zig_anchor.c")
file(WRITE "${EVCAM_ZIG_ANCHOR}" "void evcam_zig_anchor(void) {}\n")
set_source_files_properties(
        "${EVCAM_ZIG_ANCHOR}"
        PROPERTIES OBJECT_DEPENDS "${EVCAM_ZIG_DEPS};${EVCAM_ZIG_BUILD}")
file(GENERATE
        OUTPUT "${EVCAM_ZIG_LIBC_FILE}"
        CONTENT "include_dir=${CMAKE_SYSROOT}/usr/include\nsys_include_dir=${CMAKE_SYSROOT}/usr/include/aarch64-linux-android\ncrt_dir=${CMAKE_SYSROOT}/usr/lib/aarch64-linux-android/28\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n"
        NEWLINE_STYLE UNIX)

add_library(
        evcam_gles_compositor
        SHARED
        "${EVCAM_ZIG_ANCHOR}")

add_custom_command(
        TARGET evcam_gles_compositor
        POST_BUILD
        COMMAND ${ZIG_EXECUTABLE} build
                --build-file "${EVCAM_ZIG_BUILD}"
                -Dtarget=aarch64-linux-android.28
                -Doptimize=ReleaseFast
                -Dandroid-sysroot=${CMAKE_SYSROOT}
                -Dandroid-api=28
                -Dlibc-file=${EVCAM_ZIG_LIBC_FILE}
                --cache-dir "${CMAKE_CURRENT_BINARY_DIR}/zig-cache"
                --prefix "${CMAKE_CURRENT_BINARY_DIR}/zig-out"
        COMMAND ${CMAKE_COMMAND} -E copy
                "${CMAKE_CURRENT_BINARY_DIR}/zig-out/lib/libevcam_gles_compositor.so"
                $<TARGET_FILE:evcam_gles_compositor>
        VERBATIM)
