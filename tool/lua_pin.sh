# The pinned Lua release. Sourced by tool/fetch_lua.sh and
# tool/build_native_artifact.sh. native_artifacts/sources.json pins the same
# file for the build hook; tool/verify_artifacts.dart checks that they agree.
# A pin change is a reviewed change with a full test run.
LUA_VERSION=5.5.1
LUA_URL="https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
LUA_SHA256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
