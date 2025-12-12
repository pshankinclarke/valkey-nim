# Package

version       = "0.1.0"
author        = "Parker Shankin Clarke <parkerwsc1@gmail.com>"
description   = "Valkey (Redis-compatible) client for Nim"
license       = "MIT"

srcDir = "src"

# Dependencies

requires "nim >= 2.0.0"

task docs, "Build documentation":
  exec "nim doc --index:on -o:docs/valkey.html src/valkey.nim"

task test, "Run tests":
  exec "nim c -r tests/main.nim"
  exec "nim c -r --threads:on tests/main.nim"
