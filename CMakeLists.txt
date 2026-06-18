cmake_minimum_required(VERSION 3.13)

include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(trinkey_bno055 C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(trinkey_bno055
        src/main.c
        src/bno055.c
        src/i2c_utils.c
        src/neopixel.c
)

target_include_directories(trinkey_bno055 PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}/include
)

pico_generate_pio_header(trinkey_bno055
        ${CMAKE_CURRENT_LIST_DIR}/ws2812.pio
)

target_link_libraries(trinkey_bno055
        pico_stdlib
        hardware_i2c
        hardware_pio
)

pico_enable_stdio_usb(trinkey_bno055 1)
pico_enable_stdio_uart(trinkey_bno055 0)

pico_add_extra_outputs(trinkey_bno055)

add_custom_target(flash
        COMMAND ${CMAKE_SOURCE_DIR}/tools/flash_uf2.sh
        ${CMAKE_CURRENT_BINARY_DIR}/trinkey_bno055.uf2
        DEPENDS trinkey_bno055
        USES_TERMINAL
)