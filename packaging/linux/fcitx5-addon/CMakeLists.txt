cmake_minimum_required(VERSION 3.20)
project(fcitx5-openburnbar VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Fcitx5Core 5.1.6 REQUIRED)
find_package(Fcitx5Utils REQUIRED)

add_library(openburnbar-fcitx5 MODULE src/openburnbar-fcitx5.cpp)
set_target_properties(openburnbar-fcitx5 PROPERTIES PREFIX "")
target_link_libraries(openburnbar-fcitx5 Fcitx5::Core Fcitx5::Utils)

# Addon + input-method registration metadata.
install(TARGETS openburnbar-fcitx5 DESTINATION "${FCITX_INSTALL_LIBDIR}/fcitx5")
install(FILES openburnbar-fcitx5-addon.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/addon"
        RENAME openburnbar-fcitx5.conf)
install(FILES openburnbar-fcitx5-im.conf
        DESTINATION "${FCITX_INSTALL_PKGDATADIR}/inputmethod"
        RENAME openburnbar.conf)
