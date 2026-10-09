cmake_minimum_required(VERSION 3.27)

project(omarchy-hyprland-titlebars
  DESCRIPTION "Titlebars and edge snapping for Omarchy's floating workspace mode"
  VERSION 0.1.0
  LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 23)

set(SRC main.cpp barDeco.cpp BarPassElement.cpp edgeSnap.cpp)

# Built as titlebars.so (no lib prefix). Omarchy loads it from the fixed path
# /usr/lib/omarchy-hyprland-titlebars/titlebars.so. The Hyprland-facing plugin
# name stays "hyprbars" so the hl.plugin.hyprbars Lua namespace is unchanged.
add_library(titlebars SHARED ${SRC})
set_target_properties(titlebars PROPERTIES PREFIX "")
# Hyprland exposes inline globals through its headers, so whole-library hidden
# visibility breaks the host API. Our own types/globals have unique OmarchyFloating names.
target_compile_options(titlebars PRIVATE -fno-gnu-unique)

find_package(PkgConfig REQUIRED)
pkg_check_modules(deps REQUIRED IMPORTED_TARGET
  hyprland
  libdrm
  libinput
  libudev
  pixman-1
  wayland-server
  xkbcommon
)
target_link_libraries(titlebars PRIVATE rt PkgConfig::deps)

install(TARGETS titlebars LIBRARY DESTINATION lib/omarchy-hyprland-titlebars)
