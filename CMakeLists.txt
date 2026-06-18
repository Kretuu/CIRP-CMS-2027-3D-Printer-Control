cmake_minimum_required(VERSION 3.13)

set(PICO_SDK_PATH ${CMAKE_CURRENT_LIST_DIR}/external/pico-sdk)
set(PICO_BOARD adafruit_trinkey_qt2040 CACHE STRING "Pico board")

include(${PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(meng-dissertation-code C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_subdirectory(firmware/trinkey_bno055)