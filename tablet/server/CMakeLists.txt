cmake_minimum_required(VERSION 3.16)
project(rm2sidecar LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)

# EPAPER=ON: build for the reMarkable 2 (SDK). EPAPER=OFF: plain Linux build for offline tests
# (run with QT_QPA_PLATFORM=offscreen and --dump).
option(EPAPER "Use the reMarkable epaper backend" ON)

find_package(Qt6 REQUIRED COMPONENTS Quick)
find_package(ZLIB REQUIRED)

add_executable(rm2sidecar main.cpp link.cpp link.h pen.cpp pen.h)
target_link_libraries(rm2sidecar PRIVATE Qt6::Quick ZLIB::ZLIB)
if(EPAPER)
    target_compile_definitions(rm2sidecar PRIVATE RM2_EPAPER)
    # EPFramebuffer / EPScreenModeItem live in the epaper scenegraph plugin on the device.
    target_link_libraries(rm2sidecar PRIVATE ${CMAKE_SYSROOT}/usr/lib/plugins/scenegraph/libqsgepaper.so)
    set_target_properties(rm2sidecar PROPERTIES BUILD_RPATH "/usr/lib/plugins/scenegraph")
endif()
