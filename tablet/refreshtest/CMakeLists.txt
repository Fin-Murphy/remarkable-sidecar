cmake_minimum_required(VERSION 3.16)
project(refreshtest LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(Qt6 REQUIRED COMPONENTS Quick)
qt_standard_project_setup(REQUIRES 6.5)
qt_add_executable(refreshtest main.cpp)
target_link_libraries(refreshtest PRIVATE Qt6::Quick
    # EPFramebuffer / EPScreenModeItem live in the epaper scenegraph plugin on the device.
    ${CMAKE_SYSROOT}/usr/lib/plugins/scenegraph/libqsgepaper.so)
set_target_properties(refreshtest PROPERTIES BUILD_RPATH "/usr/lib/plugins/scenegraph")
