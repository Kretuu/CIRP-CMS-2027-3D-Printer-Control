cmake_minimum_required(VERSION 3.13)

set(PICO_SDK_PATH ${CMAKE_CURRENT_LIST_DIR}/external/pico-sdk)
set(PICO_BOARD adafruit_trinkey_qt2040 CACHE STRING "Pico board")

include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(meng-dissertation-code C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_subdirectory(firmware/trinkey_bno055)

# Expose the Klipper submodule to IDEs without adding it to the firmware build.
set(KLIPPER_ROOT "${CMAKE_CURRENT_LIST_DIR}/external/klipper")
if(EXISTS "${KLIPPER_ROOT}/Makefile")
    file(GLOB_RECURSE KLIPPER_IDE_FILES
            LIST_DIRECTORIES false
            CONFIGURE_DEPENDS
            "${KLIPPER_ROOT}/*")

    list(FILTER KLIPPER_IDE_FILES EXCLUDE REGEX "/\\.git/")

    add_custom_target(klipper_ide_files SOURCES ${KLIPPER_IDE_FILES})
    source_group(TREE "${KLIPPER_ROOT}" PREFIX "external/klipper" FILES ${KLIPPER_IDE_FILES})
    set_target_properties(klipper_ide_files PROPERTIES FOLDER "external")
endif()
