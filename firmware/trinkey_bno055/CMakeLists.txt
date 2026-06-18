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

add_custom_target(flash_trinkey_bno055
        COMMAND ${CMAKE_CURRENT_LIST_DIR}/tools/flash_uf2.sh
        ${CMAKE_CURRENT_BINARY_DIR}/trinkey_bno055.uf2
        DEPENDS trinkey_bno055
        USES_TERMINAL
)