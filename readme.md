# Valkey

A [Valkey](https://valkey.io/) client for Nim.

## Installation

Add the following to your `.nimble` file:

```
# Dependencies

requires "valkey >= 0.1.0"
```

Or, to install globally:

```
nimble install valkey
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

There is also a synchronous version of the client that can be created using the `connectValkey()` procedure rather than `connectValkeyAsync()`.

### PubSub

```nim
import valkey, asyncdispatch

proc main() {.async.} =
  let v = await connectValkeyAsync()
  let p = v.pubsub()

  await p.subscribe("my-first-channel")

  let msg = await p.receiveMessage()
  echo msg.channel, ": ", msg.data
  # my-first-channel: hello from valkey-cli

  await p.close()
  await v.close()

waitFor main()
```
`receiveEvent()` returns the next Pub/Sub event (you can hide or show subscribe acknowledgements with `pubsub(ignoreSubscribeMessages=true/false)`). `receiveMessage()` is a wrapper that skips everything except published messages.

## License

Released under the MIT License, the same license as `nim-lang/redis` when this project was forked.
