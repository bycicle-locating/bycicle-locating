# ESP-IDF v5.x 工程入口。
# 构建前需要 source $IDF_PATH/export.sh，然后用 idf.py。
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

project(bkl_firmware)
