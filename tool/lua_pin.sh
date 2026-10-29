# The pinned Lua release. Sourced by tool/fetch_lua.sh and
# tool/build_native_artifact.sh. native_artifacts/sources.json pins the same
# file for the build hook; tool/verify_artifacts.dart checks that they agree.
# A pin change is a reviewed change with a full test run.
LUA_VERSION=5.4.9
LUA_URL="https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
LUA_SHA256=2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6
