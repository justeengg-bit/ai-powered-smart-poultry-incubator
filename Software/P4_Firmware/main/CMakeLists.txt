idf_component_register(
    SRCS "main.cpp"
    INCLUDE_DIRS "."
    REQUIRES
        esp_wifi
        esp_event
        esp_netif
        nvs_flash
        esp_http_client
        esp_http_server
        esp_driver_jpeg
        esp_driver_gpio
        esp_driver_i2c
        esp-tflite-micro
        freertos
        log
        esp_timer
        driver
        json
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error=format-truncation -Wno-missing-field-initializers)

target_add_binary_data(${COMPONENT_LIB} "model/eggcounter_cls_int8.tflite" BINARY)
