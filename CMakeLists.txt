cmake_minimum_required(VERSION 3.16)

project(lua_dart LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(LUADART_BUILD_TESTS "Build the native ABI smoke test" OFF)

# The src/ directory of the pinned Lua release, extracted by
# tool/build_native_artifact.sh.
set(LUADART_LUA_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lua/src"
    CACHE PATH "src/ directory of the pinned Lua release")
if(NOT EXISTS "${LUADART_LUA_SOURCE}/lapi.c")
  message(FATAL_ERROR "Lua not found at ${LUADART_LUA_SOURCE}. Build with tool/build_native_artifact.sh.")
endif()

# Every file of the Lua core and standard libraries; not the lua and luac
# programs.
set(LUADART_LUA_FILES
  lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c lmem.c
  lobject.c lopcodes.c lparser.c lstate.c lstring.c ltable.c ltm.c lundump.c
  lvm.c lzio.c
  lauxlib.c lbaselib.c lcorolib.c ldblib.c liolib.c lmathlib.c loadlib.c
  loslib.c lstrlib.c ltablib.c lutf8lib.c linit.c
)
list(TRANSFORM LUADART_LUA_FILES PREPEND "${LUADART_LUA_SOURCE}/")

if(EMSCRIPTEN)
  add_library(lua_dart STATIC src/lua_dart.c ${LUADART_LUA_FILES})
else()
  add_library(lua_dart SHARED src/lua_dart.c ${LUADART_LUA_FILES})
endif()
target_include_directories(lua_dart PRIVATE "${LUADART_LUA_SOURCE}" src)

# The definitions of the reference Makefile: 5.3 compatibility, and POSIX
# functions for io and os where they exist. No LUA_USE_DLOPEN: `require`
# cannot load C libraries.
target_compile_definitions(lua_dart PRIVATE LUA_COMPAT_5_3)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # iOS has no system(): os.execute fails.
  target_compile_definitions(lua_dart PRIVATE LUA_USE_IOS)
elseif(UNIX AND NOT EMSCRIPTEN)
  target_compile_definitions(lua_dart PRIVATE LUA_USE_POSIX)
endif()

# The export lists below (src/exports_*) are the whole public surface; they
# keep the Lua API private.
if(NOT MSVC)
  target_compile_options(lua_dart PRIVATE -Wall -Wextra)
endif()

if(APPLE)
  target_link_options(lua_dart PRIVATE
    "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/src/exports_apple.txt"
  )
  set_target_properties(lua_dart PROPERTIES
    BUILD_WITH_INSTALL_RPATH ON
    INSTALL_NAME_DIR "@rpath"
  )
endif()

if(ANDROID)
  target_link_libraries(lua_dart PRIVATE m)
  # 16KB page size support with NDK 27.x; default in NDK 28+.
  target_link_options(lua_dart PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/exports_elf.map"
    "-Wl,--exclude-libs,ALL"
    "-Wl,-z,relro,-z,now"
  )
endif()

if(UNIX AND NOT APPLE AND NOT ANDROID AND NOT EMSCRIPTEN)
  target_link_libraries(lua_dart PRIVATE m)
  target_link_options(lua_dart PRIVATE
    -static-libgcc
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/exports_elf.map"
    "-Wl,--exclude-libs,ALL"
    "-Wl,-z,relro,-z,now"
  )
endif()

if(WIN32)
  # A .def file makes the whole public surface explicit and keeps the Lua
  # API private.
  target_sources(lua_dart PRIVATE src/exports_windows.def)
  if(MINGW)
    target_link_options(lua_dart PRIVATE
      -static -static-libgcc
      "-Wl,--no-insert-timestamp"
    )
  endif()
  set_target_properties(lua_dart PROPERTIES PREFIX "" OUTPUT_NAME "lua_dart")
endif()

if(LUADART_BUILD_TESTS)
  add_executable(luadart_smoke_test native_test/smoke_test.c)
  target_include_directories(luadart_smoke_test PRIVATE src)
  find_package(Threads REQUIRED)
  target_link_libraries(luadart_smoke_test PRIVATE lua_dart Threads::Threads)
endif()
