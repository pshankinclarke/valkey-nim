# valkey

A valkey client for Nim. This library is a fork of the official [`nim-lang/redis`](https://github.com/nim-lang/redis) client, adapted to work with [valkey](https://valkey.io/), while remaining compatible with redis.

## Installation

Once published, you'll be able to add the following to your `.nimble` file:

```
# Dependencies

requires "valkey >= 0.1.0"
```

Or, to install globally to your Nimble cache run the following command (from git until published):

```
nimble install https://github.com/pshankinclarke/valkey-nim@#valkey
```

## Usage

```nim
import valkey, asyncdispatch

proc main() {.async.} =
  ## Open a connection to Valkey running on localhost on the default port (6379)
  let valkeyClient = await connectValkeyAsync()

  ## Set the key `nim_valkey:test` to the value `Hello, World`
  await valkeyClient.setk("nim_valkey:test", "Hello, World")

  ## Get the value of the key `nim_valkey:test`
  let value = await valkeyClient.get("nim_valkey:test")

  assert(value == "Hello, World")

waitFor main()
```

There is also a synchronous version of the client, that can be created using the `connectValkey()` procedure rather than `connectValkeyAsync()`.

## License

Copyright (C) 2015, 2017 Dominik Picheta and contributors. Forked and adapted for Valkey by Parker Shankin-Clarke.  All rights reserved.
