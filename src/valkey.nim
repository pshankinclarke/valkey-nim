#
#
#            Nim's Runtime Library
#        (c) Copyright 2019 Dominik Picheta
#               and contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#
#    Forked and adapted for Valkey by Parker Shankin-Clarke, 2025.

## This module implements a valkey client. It allows you to connect to a
## valkey-server instance, send commands and receive replies.
##
## **Beware**: Most (if not all) functions that return a ``ValkeyString`` may
## return ``valkeyNil``.
##
## Example
## --------
##
## .. code-block::nim
##    import valkey, asyncdispatch
##
##    proc main() {.async.} =
##      ## Open a connection to Valkey running on localhost on the default port (6379)
##      let valkeyClient = await connectValkeyAsync()
##
##      ## Set the key `nim_valkey:test` to the value `Hello, World`
##      await valkeyClient.setk("nim_valkey:test", "Hello, World")
##
##      ## Get the value of the key `nim_valkey:test`
##      let value = await valkeyClient.get("nim_valkey:test")
##
##      assert(value == "Hello, World")
##
##    waitFor main()

import std/net, asyncdispatch, asyncnet, os, strutils, parseutils, deques, options, sets, sequtils

const
  valkeyNil* = "\0\0"
  redisNil* = valkeyNil

type
  Pipeline = ref object
    enabled: bool
    buffer: string
    expected: int
    ## expected: increments once per queued command added to buffer (via sendCommand with pipelining).
    ## It equals the number of top-level replies that must be read after sending buffer.
    ## For multi/exec, the elements inside the EXEC array reply are not counted in expected.
    ## TODO: add inMulti flag

  ValkeyTlsState = ref object
    # placeholder for TLS state

  ValkeyBase[TSocket] = ref object of RootObj
    socket: TSocket
    connected: bool
    pipeline: Pipeline
    tlsActive: bool
    tlsState: ValkeyTlsState

  Valkey* = ref object of ValkeyBase[net.Socket]
    ## A synchronous valkey client.

  ValkeyTlsOptions* = object
    cacert_filename*: string
    capath*: string
    cert_filename*: string
    private_key_filename*: string
    server_name*: string
    verify_mode*: int

  # stub for now
  ValkeyTlsContext* = object

  ValkeyConnParams* = object
    host*: string
    port*: Port
    username*: string
    password*: string
    db*: int
    useTls*: bool
    tls*: Option[ValkeyTlsOptions]

    # TODO: add timeouts once reconnect is implemented

  AsyncValkey* = ref object of ValkeyBase[asyncnet.AsyncSocket]
    ## An asynchronous valkey client.
    currentCommand: Option[string]
    sendQueue: Deque[Future[void]]
    params: ValkeyConnParams

  ValkeyStatus* = string
  ValkeyInteger* = BiggestInt
  ValkeyString* = string
    ## Bulk reply
  ValkeyList* = seq[ValkeyString]
    ## Multi-bulk reply
  ValkeyMessage* = object
    ## Pub/Sub
    channel*: string
    message*: string

  ValkeyCursor* = ref object
    position*: BiggestInt

  EngineKind* = enum
   ekUnknown,
   ekValkey,
   ekRedis

  ## --- Errors ---
  ValkeyError* = object of CatchableError  # default
  ConnectionError* = object of ValkeyError # transport/socket
  # TODO: leave until we have timeouts implemented
  TimeoutError* = object of ConnectionError
  ProtocolError* = object of ValkeyError   # invalid reply
  ResponseError* = object of ValkeyError   # server returned -ERR (not a transport error).
    code*: string # e.g., "ERR", "WRONGTYPE"
    cmd*: string  # the command that caused the error
  ExecAbortError* = object of ResponseError
  WatchError* = object of ValkeyError     # transaction error. Caller should retry the entire transaction.
  PubSubError* = object of ValkeyError

  # legacy error types (aliases)
  ReplyError* = ProtocolError
  RedisError* = ValkeyError
  ## --- Redis aliases ---

  Redis* = Valkey
  AsyncRedis* = AsyncValkey
  RedisStatus* = ValkeyStatus
  RedisInteger* = ValkeyInteger
  RedisString* = ValkeyString
  RedisList* = ValkeyList
  RedisMessage* = ValkeyMessage
  RedisCursor* = ValkeyCursor

  ## --- Pub/Sub ---
  PubSubEventKind* = enum
    pekUnknown,
    pekSubscribe, pekUnsubscribe,
    pekPSubscribe, pekPUnsubscribe,
    pekSSubscribe, pekSUnsubscribe,
    pekMessage, pekPMessage, pekSMessage,
    pekPong

  PubSubEvent* = object
    kind*: PubSubEventKind
    pattern*: string
    channel*: string
    data*: string    # payload for message/pmessage/smessage/pong
    count*: int      # subscription/unsubscribe/...; -1 when not applicable

  AsyncPubSub* = ref object
    params*: ValkeyConnParams
    conn*: AsyncValkey             # nil until first subscribe
    ignoreSubscribeMessages*: bool
    channels*: HashSet[string]
    patterns*: HashSet[string]
    shardChannels*: HashSet[string]
    # TODO: add a closed flag

    pendingUnsubChannels*: HashSet[string]
    pendingUnsubPatterns*: HashSet[string]
    pendingUnsubShardChannels*: HashSet[string]

    subscribed*: bool # at least one active sub
    subscribedFut*: Future[void] # completes when 0 -> >0, resets when >0 -> 0

    pendingPing: int

# tls proc stubs

# Initialize an OpenSSL configuration object
proc tlsContextInit*(opts: ValkeyTlsOptions): ValkeyTlsContext =
  discard opts
  result = ValkeyTlsContext() # placeholder

# Free prior created OpenSSL context
proc tlsContextFree*(ctx: var ValkeyTlsContext) =
  discard ctx

# Initialize TLS on an already connected TCP client
proc initiateTls*(r: Valkey | AsyncValkey, ctx: ValkeyTlsContext; sni="") =
  discard r
  discard ctx
  discard sni

## Error helpers

proc newValkeyError*(msg: string): ref ValkeyError =
  result = newException(ValkeyError, msg)

proc newConnError*(msg: string): ref ConnectionError =
  result = newException(ConnectionError, msg)

proc newTimeoutError*(msg: string): ref TimeoutError =
  result = newException(TimeoutError, msg)

proc newPubSubError*(msg: string): ref PubSubError =
  result = newException(PubSubError, msg)

proc newWatchError*(msg: string): ref WatchError =
  result = newException(WatchError, msg)

proc newResponseError*(msg: string; code: string = ""; cmd: string = ""): ref ResponseError =
  result = newException(ResponseError, msg)
  result.code = code
  result.cmd = cmd

proc newExecAbortError*(msg: string; code: string = "EXECABORT"; cmd: string = ""): ref ExecAbortError =
  result = newException(ExecAbortError, msg)
  result.code = code
  result.cmd = cmd

proc newProtocolError*(msg: string): ref ProtocolError =
  result = newException(ProtocolError, msg)

proc raiseValkeyError*(msg: string) =
  raise newValkeyError(msg)

proc raiseConnError*(msg: string) =
  raise newConnError(msg)

proc raiseTimeoutError*(msg: string) =
  raise newTimeoutError(msg)

proc raisePubSubError*(msg: string) =
  raise newPubSubError(msg)

proc raiseWatchError*(msg: string) =
  raise newWatchError(msg)

proc raiseExecAbortError*(msg: string; code: string = "EXECABORT"; cmd: string = "") =
  raise newExecAbortError(msg, code, cmd)

proc raiseResponseError*(msg: string; code: string = ""; cmd: string = "") =
  raise newResponseError(msg, code, cmd)

proc raiseProtocolError*(msg: string) =
  raise newProtocolError(msg)

# helpers for cmd  execution paths that need to finalise command before raising
# TODO: Figure out how to merge with above? Trying to avoid the "legacy" finaliseCommand() getting called inside of pubsub.

proc failAllSendQueue(r: AsyncRedis, e: ref Exception) =
  while r.sendQueue.len > 0:
    let fut = r.sendQueue.popFirst()
    if not fut.finished:
      fut.fail(e)

proc cmdName(r: Redis | AsyncRedis): string =
  ## captures currentCommand before finaliseCommand clears it
  when r is AsyncRedis:
    result = r.currentCommand.get("") # Option[string] -> string
  else:
    result = ""
proc finaliseCommand(r: Redis | AsyncRedis)

proc raiseConnErrorCmd*(r: Redis | AsyncRedis, msg: string) =
  when r is AsyncRedis:
    let e = newConnError(msg)
    r.currentCommand = none(string)
    failAllSendQueue(r, e)

    r.pipeline.enabled = false
    r.pipeline.expected = 0
    r.pipeline.buffer = ""

    try: r.socket.close()
    except CatchableError: discard
    raise e
  else:
    r.pipeline.enabled = false
    r.pipeline.expected = 0
    r.pipeline.buffer = ""

    try: r.socket.close()
    except CatchableError: discard
    raiseConnError(msg)

proc raiseTimeoutErrorCmd*(r: Redis | AsyncRedis, msg: string) =
  when r is AsyncRedis:
    let e = newTimeoutError(msg)
    r.currentCommand = none(string)
    failAllSendQueue(r, e)

    r.pipeline.enabled = false
    r.pipeline.expected = 0
    r.pipeline.buffer = ""

    try: r.socket.close()
    except CatchableError: discard
    raise e
  else:
    r.pipeline.enabled = false
    r.pipeline.expected = 0
    r.pipeline.buffer = ""

    try: r.socket.close()
    except CatchableError: discard
    raiseTimeoutError(msg)

proc raiseProtocolErrorCmd*(r: Redis | AsyncRedis, msg: string) =
  when r is AsyncRedis:
    let e = newProtocolError(msg)
    r.currentCommand = none(string)
    failAllSendQueue(r, e)

    r.pipeline.enabled = false
    r.pipeline.expected = 0
    r.pipeline.buffer = ""

    try: r.socket.close()
    except CatchableError: discard
    raise e
  else:
    r.pipeline.enabled = false
    r.pipeline.expected = 0
    r.pipeline.buffer = ""

    try: r.socket.close()
    except CatchableError: discard
    raiseProtocolError(msg)

# TODO: best attempt, currently cmd tracking is only reliable for Async non-pipelined commands
# adding cmd tracking to pipeline.cmd and sync mode (last send cmd stored in Valkey?) would help here
proc raiseResponseErrorCmd*(r: Redis | AsyncRedis, msg: string; code: string = ""; cmd: string = "") =
  # capture cmd before finaliseCommand clears it (AsyncRedis only)
  let cmd0 = if cmd.len != 0: cmd else: cmdName(r)
  finaliseCommand(r)
  raiseResponseError(msg, code = code, cmd = cmd0)

proc raiseExecAbortErrorCmd*(r: Redis | AsyncRedis, msg: string; code: string = "EXECABORT"; cmd: string = "") =
  # capture cmd before finaliseCommand clears it (AsyncRedis only)
  let cmd0 = if cmd.len != 0: cmd else: cmdName(r)
  finaliseCommand(r)
  raiseExecAbortError(msg, code = code, cmd = cmd0)

proc raiseValkeyErrorCmd*(r: Redis | AsyncRedis, msg: string) =
  finaliseCommand(r)
  raiseValkeyError(msg)

proc raiseWatchErrorCmd*(r: Redis | AsyncRedis, msg: string) =
  finaliseCommand(r)
  raiseWatchError(msg)

proc sendRaw(r: Redis | AsyncRedis, data: string): Future[void] {.multisync.} =
  ## Raw transport send. No currentCommand/sendQueue bookkeeping. 
  when r is Redis:
    try:
      r.socket.send(data)
    except CatchableError as e:
      raiseConnErrorCmd(r, "send failed: " & e.msg)
  else:
    try:
      await r.socket.send(data)
    except CatchableError as e:
      raiseConnErrorCmd(r, "send failed: " & e.msg)

proc recvExact(r: Redis | AsyncRedis, size: int): Future[string] {.multisync.} =
  ## Raw transport recv of exactly size bytes.
  result = newString(size)
  when r is Redis:
    try:
      if r.socket.recv(result, size) != size:
        raiseConnErrorCmd(r, "recv failed")
    except CatchableError as e:
      raiseConnErrorCmd(r, "recv failed: " & e.msg)
  else:
    try:
      let numReceived = await r.socket.recvInto(addr result[0], size)
      if numReceived != size:
        raiseConnErrorCmd(r, "recv failed")
    except CatchableError as e:
      raiseConnErrorCmd(r, "recv failed: " & e.msg)

proc recvLineRaw(r: Redis | AsyncRedis): Future[string] {.multisync.} =
  ## Raw transport recv of a line (up to \r\n).
  when r is Redis:
    try:
      result = net.recvLine(r.socket)
    except CatchableError as e:
      raiseConnErrorCmd(r, "recvLine failed: " & e.msg)
  else:
    try:
      result = await asyncnet.recvLine(r.socket)
    except CatchableError as e:
      raiseConnErrorCmd(r, "recvLine failed: " & e.msg)

proc newPipeline(): Pipeline =
  new(result)
  result.buffer = ""
  result.enabled = false
  result.expected = 0

proc newCursor*(pos: BiggestInt = 0): RedisCursor =
  result = RedisCursor(
    position: pos
  )

proc `$`*(cursor: RedisCursor): string =
  result = $cursor.position

proc open*(host = "localhost", port = 6379.Port): Redis =
  ## Open a synchronous connection to a valkey/redis server.
  result = Redis(
    socket: newSocket(buffered = true),
    pipeline: newPipeline()
  )

  result.socket.connect(host, port)

## TODO: consider storing conn params for unix sockets
proc openUnix*(path = "/var/run/redis/redis.sock"): Redis =
  ## Open a synchronous unix connection to a valkey/redis server.
  result = Redis(
    socket: newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP, buffered = false),
    pipeline: newPipeline()
  )

  result.socket.connectUnix(path)

proc openAsync*(host = "localhost", port = 6379.Port): Future[AsyncRedis] {.async.} =
  ## Open an asynchronous connection to a valkey/redis server.
  result = AsyncRedis(
    socket: newAsyncSocket(buffered = true),
    pipeline: newPipeline(),
    sendQueue: initDeque[Future[void]]()
  )
  result.params = ValkeyConnParams(
    host: host,
    port: port,
    db: 0,
    username: "",
    password: "",
    useTls: false,
    tls: none(ValkeyTlsOptions)
  )

  await result.socket.connect(host, port)

proc openUnixAsync*(path = "/var/run/redis/redis.sock"): Future[AsyncRedis] {.async.} =
  ## Open an asynchronous unix connection to a valkey/redis server.
  result = AsyncRedis(
    socket: newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP, buffered = false),
    pipeline: newPipeline(),
    sendQueue: initDeque[Future[void]]()
  )

  await result.socket.connectUnix(path)

proc finaliseCommand(r: Redis | AsyncRedis) =
  when r is AsyncRedis:
    r.currentCommand = none(string)
    if r.sendQueue.len > 0:
      let fut = r.sendQueue.popFirst()
      fut.complete()

proc raiseReplyError(r: Redis | AsyncRedis, msg: string) =
  raiseProtocolErrorCmd(r, msg)

proc respErrCode(msg: string): string =
  var s  = msg.strip()
  if s.len == 0: return ""

  # error frames are "-<code> <message>"
  if s[0] == '-':
    if s.len == 1: return ""
    s = s[1 .. ^1].strip()
  let parts = s.splitWhitespace()
  if parts.len == 0:
    result = ""
  else:
    result = parts[0]

# TODO: map common error codes to specific error types
proc raiseRedisError(r: Redis | AsyncRedis, msg: string) =
  let code = respErrCode(msg)
  if code == "EXECABORT":
    raiseExecAbortErrorCmd(r, msg, code = code)
  else:
    raiseResponseErrorCmd(r, msg, code = code)

proc managedSend(
  r: Redis | AsyncRedis, data: string, cmd: string = ""
): Future[void] {.multisync.} =
  when r is Redis:
    r.sendRaw(data)
  else:
    if r.currentCommand.isSome():
      # Queue this send.
      let sendFut = newFuture[void]("redis.managedSend")
      r.sendQueue.addLast(sendFut)
      await sendFut

    r.currentCommand = some(cmd)
    await r.sendRaw(data)

proc managedRecv(
  r: Redis | AsyncRedis, size: int
): Future[string] {.multisync.} =
  when r is Redis:
    result = r.recvExact(size)
  else:
    result = await r.recvExact(size)

proc managedRecvPubSub(r: Redis | AsyncRedis, size: int): Future[string] {.multisync.} =
  ## Raw transport recv for Pub/Sub paths
  ## Raises ConnectionError on short read/EOF; doesn't touch cmd state
  result = newString(size)
  var bytesRead: int
  when r is Redis:
    try:
      bytesRead = r.socket.recv(result, size)
    except CatchableError as e:
      raiseConnError("recv failed: " & e.msg)
  else:
    try:
      bytesRead = await r.socket.recvInto(addr result[0], size)
    except CatchableError as e:
      raiseConnError("recv failed: " & e.msg)
  if bytesRead != size:
    raiseConnError("recv failed")

proc managedRecvLine(r: Redis | AsyncRedis): Future[string] {.multisync.} =
  if r.pipeline.enabled:
    result = ""
  else:
    when r is Redis:
      result = r.recvLineRaw()
    else:
      result = await r.recvLineRaw()

proc raiseInvalidReply(r: Redis | AsyncRedis, expected, got: char) =
  raiseReplyError(r,
          "Expected '$1' at the beginning of a status reply got '$2'" %
          [$expected, $got])

proc raiseNoOK(r: Redis | AsyncRedis, status: string) =
  let pipelined = r.pipeline.enabled
  if pipelined and not (status == "QUEUED" or status == "PIPELINED"):
    raiseReplyError(r, "Expected \"QUEUED\" or \"PIPELINED\" got \"$1\"" % status)
  elif not pipelined and status != "OK":
    raiseReplyError(r, "Expected \"OK\" got \"$1\"" % status)

proc parseStatus(r: Redis | AsyncRedis, line: string = ""): RedisStatus =
  if r.pipeline.enabled:
    return "PIPELINED"

  if line.len == 0:
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  if line[0] == '-':
    raiseRedisError(r, strip(line))
  if line[0] != '+':
    raiseInvalidReply(r, '+', line[0])

  result = line.substr(1) # Strip '+'

proc readStatus(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return "PIPELINED"
    raiseConnErrorCmd(r, "Server closed connection prematurely")
  result = r.parseStatus(line)
  finaliseCommand(r)

proc parseInteger(r: Redis | AsyncRedis, line: string = ""): RedisInteger =
  if r.pipeline.enabled:
    return -1

  if line.len == 0:
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  #if line == "+QUEUED":  # inside of multi
  #  return -1

  if line[0] == '-':
    raiseRedisError(r, strip(line))
  if line[0] != ':':
    raiseInvalidReply(r, ':', line[0])

  # Strip ':'
  if parseBiggestInt(line, result, 1) == 0:
    raiseReplyError(r, "Unable to parse integer.")

proc parseIntegerPubSub(line: string): RedisInteger =
  if line.len == 0:
    raiseConnError("Server closed connection prematurely")
  if line[0] == '-':
    raiseResponseError((strip(line)),code = respErrCode(line))
  if line[0] != ':':
    raiseProtocolError("Expected ':' at the beginning of an integer reply")
  if parseBiggestInt(line, result, 1) == 0:
    raiseProtocolError("Unable to parse integer: " & line)

proc readInteger(r: Redis | AsyncRedis): Future[RedisInteger] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return -1
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  result = r.parseInteger(line)
  finaliseCommand(r)

proc readSingleString(
  r: Redis | AsyncRedis, line: string, allowMBNil: bool
): Future[Option[RedisString]] {.multisync.} =
  if r.pipeline.enabled: return none(RedisString)

  if line.len == 0:
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  # Error.
  if line[0] == '-':
    raiseRedisError(r, strip(line))

  # Some commands return a /bulk/ value or a /multi-bulk/ nil. Odd.
  if allowMBNil:
    if line == "*-1":
       return

  if line[0] != '$':
    raiseInvalidReply(r, '$', line[0])

  var numBytes: int
  try:
    numBytes = parseInt(line.substr(1))
  except ValueError:
    raiseProtocolErrorCmd(r, "Unable to parse bulk string length " & line)
  if numBytes == -1:
    return

  var s = await r.managedRecv(numBytes + 2)
  result = some(s[0 ..< numBytes]) # Strip \r\n

proc readSingleString(r: Redis | AsyncRedis): Future[RedisString] {.multisync.} =
  # TODO: Rename these style of procedures to `processSingleString`?
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return ""
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  let res = await r.readSingleString(line, allowMBNil = false)
  result = res.get(redisNil)
  finaliseCommand(r)

proc readSingleStringPubSub(r: Redis | AsyncRedis, line: string, allowMBNil: bool): Future[Option[RedisString]] {.multisync.} =
  if line.len == 0:
    raiseConnError("Server closed connection prematurely")

  # Error.
  if line[0] == '-':
    raiseResponseError(strip(line), code = respErrCode(line))

  if allowMBNil and line == "$-1":
    return none(RedisString)

  if line[0] != '$':
    raiseProtocolError("Expected '$' at the beginning of a bulk string reply got '" & $line[0] & "'")

  var numBytes: int
  try:
    numBytes = parseInt(line.substr(1))
  except ValueError:
    raiseProtocolError("Unable to parse bulk string length " & line)

  if numBytes == -1:
    return none(RedisString)

  var s = await r.managedRecvPubSub(numBytes + 2)
  result = some(s[0 ..< numBytes]) # Strip \r\n

proc readNext(r: Redis): RedisList {.gcsafe.}
proc readNext(r: AsyncRedis): Future[RedisList] {.gcsafe.}
proc readArrayLines(r: Redis | AsyncRedis, countLine: string): Future[RedisList] {.multisync.} =
  if countLine.len == 0:
    raiseConnErrorCmd(r, "Server closed connection prematurely")
  if countLine[0] != '*':
    raiseInvalidReply(r, '*', countLine[0])
  var numElems: int
  try:
    numElems = parseInt(countLine.substr(1))
  except ValueError:
    raiseProtocolErrorCmd(r, "Unable to parse array length " & countLine)

  result = @[]

  if numElems == -1:
    return result

  for i in 1..numElems:
    when r is Redis:
      let parsed = r.readNext()
    else:
      let parsed = await r.readNext()

    if parsed.len > 0:
      for item in parsed:
        result.add(item)


proc readPubSubElement(r: Redis | AsyncRedis; firstLine: string): Future[string] {.multisync, gcsafe.} =
  if firstLine.len == 0:
    raiseConnError("pubsub connection closed")
  case firstLine[0]
  of '+':
    # status: +PONG / +OK / etc
    return firstLine.substr(1)
  of '-':
    raiseResponseError(strip(firstLine), code = respErrCode(firstLine))
  of ':':
    return $(parseIntegerPubSub(firstLine))
  of '$':
    let x = await r.readSingleStringPubSub(firstLine, true)
    return x.get(redisNil)
  of '*':
    # nested array: flatten with a delimiter or raise; Pub/Sub shouldn't have nested arrays
    raiseProtocolError("Unexpected nested array in Pub/Sub message")
  else:
    raiseProtocolError("readPubSubElement failed on line: " & firstLine)

proc readPubSubArrayLines(r: Redis | AsyncRedis; countLine: string):Future[RedisList] {.multisync, gcsafe.} =
  if countLine.len == 0:
    raiseConnError("pubsub connection closed")
  if countLine[0] != '*':
    raiseProtocolError("Expected '*' at the beginning of a Pub/Sub array reply got '" & $countLine[0] & "'")
  var n: int
  try:
    n = parseInt(countLine.substr(1))
  except ValueError:
    raiseProtocolError("Unable to parse Pub/Sub array length " & countLine)
  result = @[]
  if n == -1:
    raiseProtocolError("Unexpected nil array (*-1) in Pub/Sub frame")
  for _ in 0..<n:
    let line = await r.managedRecvLine()
    if line.len == 0:
      raiseConnError("pubsub connection closed")
    result.add(await r.readPubSubElement(line))

proc readArrayLines(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return @[]
    raiseConnErrorCmd(r, "Server closed connection prematurely")
  result = await r.readArrayLines(line)

proc readBulkString(r: Redis | AsyncRedis, allowMBNil = false): Future[RedisString] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return ""
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  let res = await r.readSingleString(line, allowMBNil)
  result = res.get(redisNil)
  finaliseCommand(r)

proc readArray(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return @[]
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  result = await r.readArrayLines(line)
  finaliseCommand(r)

proc readNext(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  let line = await r.managedRecvLine()
  if line.len == 0:
    if r.pipeline.enabled: return @[]
    raiseConnErrorCmd(r, "Server closed connection prematurely")

  # TODO: This is no longer an expression due to
  # https://github.com/nim-lang/Nim/issues/8399
  case line[0]
  of '*': return await r.readArrayLines(line)
  of '$':
    let x = await r.readSingleString(line, allowMBNil = true)
    return @[x.get(redisNil)]
  of ':': return @[$(r.parseInteger(line))]
  of '+': return @[line.substr(1)]
  of '-':
    raiseRedisError(r, strip(line))
  else:
    raiseProtocolErrorCmd(r, "readNext failed on line: " & line)

# TODO: RESP2 only for now - RESP3 push support later
proc readPubSubFrame*(r: Redis | AsyncRedis): Future[RedisList] {.multisync, gcsafe.} =
  ## Reads exactly one RESP frame from the socket (subscribe acks, messages, pong, etc.)
  ## Does not touch pipeline.expected.
  ##
  ## In Pub/Sub mode, the frames are push messages and are not 1:1 with commands,
  ## so pipeline book keeping would be incorrect here.
  let line = await r.managedRecvLine()

  ## In pubsub, returning @[] is ambiguous and empty lines should trigger disconnect/EOF.
  if line.len == 0:
    raiseConnError("pubsub connection closed")


  case line[0]
  of '*':
    return await r.readPubSubArrayLines(line)
  of '+':
    return @[line.substr(1)]
  of '-':
    raiseResponseError(strip(line), code = respErrCode(line))
  of ':':
    return @[$(parseIntegerPubSub(line))]
  of '$':
    let x = await r.readSingleStringPubSub(line, true)
    return @[x.get(redisNil)]
  else:
    raiseProtocolError("readPubSubFrame failed on line: " & line)

proc drainRespFrame(r: Redis | AsyncRedis; firstLine = ""): Future[void] {.multisync.} =
  ## consume one RESP2 frame from the socket
  var line = firstLine
  if line.len == 0:
    line = await r.managedRecvLine() # if caller already read first line, pass the header line in
  if line.len == 0:
    raiseConnErrorCmd(r, "Server closed connection prematurely")
  case line[0]
  of '+', '-', ':': # status, error, integer (ie scalar)
    discard
  of '$': # bulk string
    var n: int
    try:
      n = parseInt(line.substr(1))
    except ValueError:
      raiseProtocolErrorCmd(r, "Unable to parse bulk string length " & line)
    if n>=0:
      discard await r.managedRecv(n + 2) # payload + \r\n
    # $-1 is nil bulk string, nothing to read
  of '*': # array
    var n: int 
    try:
      n = parseInt(line.substr(1))
    except ValueError:
      raiseProtocolErrorCmd(r, "Unable to parse array length " & line)
    if n >= 0:
      for _ in 0..<n:
        await r.drainRespFrame()
    # *-1 is nil array, nothing to read
  else:
    raiseProtocolErrorCmd(r, "Unknown RESP frame type: " & line)

proc flushPipeline*(r: Redis | AsyncRedis, wasMulti = false): Future[RedisList] {.multisync.} =
  ## Send buffered commands, clear buffer, return results
  ## After sending pipeline.buffer, exactly pipeline.expected top-level replies are read.
  ##
  ## Server reply error (ResponseError / ExecAbortError) are deferred until the remaining
  ## replies are drained via drainRespFrame (no partial results are returned on error).
  ##
  ## Transport/protocol errors raise immediately.
  ## TODO: consider a "collect all" variant that returns partial results and all errors.
  when r is AsyncRedis:
    ## Pipelined bypass managedSend() (which uses sendQueue),
    ## so flushPipeline needs exclusive access to the connection.
    if r.currentCommand.isSome() or r.sendQueue.len > 0:
      raise newValkeyError("flushPipeline requires exclusive access to the connection")

  if r.pipeline.buffer.len > 0:
    when r is Redis:
      r.sendRaw(r.pipeline.buffer)
    else:
      await r.sendRaw(r.pipeline.buffer)

  # enter "read and reply" phase, clean buffer and disable pipelining
  r.pipeline.buffer = ""
  r.pipeline.enabled = false
  result = @[]

  # read replies
  let tot = r.pipeline.expected
  defer:
    r.pipeline.expected = 0

  # remember first server error but keep draining so socket stays in sync
  var firstServerError: ref Exception = nil

  # each iteration reads one reply except for multi/exec when command returns array
  for i in 0..<tot:
    if not firstServerError.isNil:
      # if an error is already seen, drain only
      await r.drainRespFrame()
      continue

    # EXEC reply
    if wasMulti and i == tot - 1:
      let line = await r.managedRecvLine()
      if line.len == 0:
        raiseConnErrorCmd(r, "Server closed connection prematurely")
      if line == "*-1":
        raiseWatchErrorCmd(r, "Transaction aborted (WATCH conflict)")
      if line[0] == '-':
        raiseRedisError(r, strip(line))
      if line[0] != '*':
        raiseProtocolErrorCmd(r, "Expected '*' at the beginning of an array reply got '" & $line[0] & "'")

      # parse array
      var n: int
      try:
        n = parseInt(line.substr(1))
      except ValueError:
        raiseProtocolErrorCmd(r, "Unable to parse array length " & line)

      if n == -1:
        raiseWatchErrorCmd(r, "Transaction aborted (WATCH conflict)")

      # read n elements of the array
      for _ in 0..<n:
        if not firstServerError.isNil:
          await r.drainRespFrame()
          continue

        try:
          let elem = await r.readNext()
          for item in elem:
            result.add(item)
        except ExecAbortError:
          if firstServerError.isNil:
            firstServerError = getCurrentException()
        except ResponseError:
          if firstServerError.isNil:
            firstServerError = getCurrentException()

    # normal reply
    else:
      try:
        let ret = await r.readNext()
        for item in ret:
          if wasMulti and (item == "OK" or item == "QUEUED"):
            discard
          else:
            result.add(item)
      except ExecAbortError:
        if firstServerError.isNil:
          firstServerError = getCurrentException()
      except ResponseError:
        if firstServerError.isNil:
          firstServerError = getCurrentException()

  if not firstServerError.isNil:
    raise firstServerError

# TODO: Async pipelining/flushPipeline assumes exclusive access to the connection
# not safe with concurrent commands. Future: add per-connection IO lock or dedicated reader/writer task.
proc startPipelining*(r: Redis | AsyncRedis) =
  ## Enable command pipelining (reduces network roundtrips).
  ## Note that when enabled, you must call flushPipeline to actually send commands, except
  ## for multi/exec() which enable and flush the pipeline automatically.
  ## Commands return immediately with dummy values; actual results returned from
  ## flushPipeline() or exec()
  r.pipeline.buffer = "" # clear buffer so stale commands aren't sent
  r.pipeline.expected = 0
  r.pipeline.enabled = true

proc sendCommand(r: Redis | AsyncRedis, cmd: string): Future[void] {.multisync.} =
  var request = "*1\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.buffer.add(request)
    r.pipeline.expected += 1
  else:
    await r.managedSend(request, cmd = cmd)

proc sendCommand(
  r: Redis | AsyncRedis, cmd: string, args: seq[string]
): Future[void] {.multisync.} =
  var request = "*" & $(1 + args.len()) & "\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")
  for i in items(args):
    request.add("$" & $i.len() & "\c\L")
    request.add(i & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.buffer.add(request)
    r.pipeline.expected += 1
  else:
    await r.managedSend(request, cmd = cmd)

proc sendCommand(
  r: Redis | AsyncRedis, cmd: string, arg1: string
): Future[void] {.multisync.} =
  var request = "*2\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")
  request.add("$" & $arg1.len() & "\c\L")
  request.add(arg1 & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.expected += 1
    r.pipeline.buffer.add(request)
  else:
    await r.managedSend(request, cmd = cmd)

proc sendCommand(r: Redis | AsyncRedis, cmd: string, arg1: string,
                 args: seq[string]): Future[void] {.multisync.} =
  var request = "*" & $(2 + args.len()) & "\c\L"
  request.add("$" & $cmd.len() & "\c\L")
  request.add(cmd & "\c\L")
  request.add("$" & $arg1.len() & "\c\L")
  request.add(arg1 & "\c\L")
  for i in items(args):
    request.add("$" & $i.len() & "\c\L")
    request.add(i & "\c\L")

  if r.pipeline.enabled:
    r.pipeline.expected += 1
    r.pipeline.buffer.add(request)
  else:
    await r.managedSend(request, cmd = cmd)

# Keys

proc del*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Delete a key or multiple keys
  await r.sendCommand("DEL", keys)
  result = await r.readInteger()

proc exists*(r: Redis | AsyncRedis, key: string): Future[bool] {.multisync.} =
  ## Determine if a key exists
  await r.sendCommand("EXISTS", @[key])
  result = (await r.readInteger()) == 1

proc expire*(r: Redis | AsyncRedis, key: string, seconds: int): Future[bool] {.multisync.} =
  ## Set a key's time to live in seconds. Returns `false` if the key could
  ## not be found or the timeout could not be set.
  await r.sendCommand("EXPIRE", key, @[$seconds])
  result = (await r.readInteger()) == 1

proc expireAt*(r: Redis | AsyncRedis, key: string, timestamp: int): Future[bool] {.multisync.} =
  ## Set the expiration for a key as a UNIX timestamp. Returns `false`
  ## if the key could not be found or the timeout could not be set.
  await r.sendCommand("EXPIREAT", key, @[$timestamp])
  result = (await r.readInteger()) == 1

proc keys*(r: Redis | AsyncRedis, pattern: string): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern
  await r.sendCommand("KEYS", pattern)
  result = await r.readArray()

proc scan*(r: Redis | AsyncRedis, cursor: RedisCursor): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern and yield it to client in portions
  ## using default Redis values for MATCH and COUNT parameters
  await r.sendCommand("SCAN", $cursor.position)
  let reply = await r.readArray()
  cursor.position = strutils.parseBiggestInt(reply[0])
  result = reply[1..high(reply)]

proc scan*(r: Redis | AsyncRedis, cursor: RedisCursor, pattern: string): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern and yield it to client in portions
  ## using cursor as a client query identifier. Using default Redis value for COUNT argument
  await r.sendCommand("SCAN", $cursor.position, @["MATCH", pattern])
  let reply = await r.readArray()
  cursor.position = strutils.parseBiggestInt(reply[0])
  result = reply[1..high(reply)]

proc scan*(r: Redis | AsyncRedis, cursor: RedisCursor, pattern: string, count: int): Future[RedisList] {.multisync.} =
  ## Find all keys matching the given pattern and yield it to client in portions
  ## using cursor as a client query identifier.
  await r.sendCommand("SCAN", $cursor.position, @["MATCH", pattern, "COUNT", $count])
  let reply = await r.readArray()
  cursor.position = strutils.parseBiggestInt(reply[0])
  result = reply[1..high(reply)]

proc move*(r: Redis | AsyncRedis, key: string, db: int): Future[bool] {.multisync.} =
  ## Move a key to another database. Returns `true` on a successful move.
  await r.sendCommand("MOVE", key, @[$db])
  result = (await r.readInteger()) == 1

proc persist*(r: Redis | AsyncRedis, key: string): Future[bool] {.multisync.} =
  ## Remove the expiration from a key.
  ## Returns `true` when the timeout was removed.
  await r.sendCommand("PERSIST", key)
  return (await r.readInteger()) == 1

proc randomKey*(r: Redis | AsyncRedis): Future[RedisString] {.multisync.} =
  ## Return a random key from the keyspace
  await r.sendCommand("RANDOMKEY")
  result = await r.readBulkString()

proc rename*(r: Redis | AsyncRedis, key, newkey: string): Future[RedisStatus] {.multisync.} =
  ## Rename a key.
  ##
  ## **WARNING:** Overwrites `newkey` if it exists!
  await r.sendCommand("RENAME", key, @[newkey])
  raiseNoOK(r, await r.readStatus())

proc renameNX*(r: Redis | AsyncRedis, key, newkey: string): Future[bool] {.multisync.} =
  ## Same as ``rename`` but doesn't continue if `newkey` exists.
  ## Returns `true` if key was renamed.
  await r.sendCommand("RENAMENX", key, @[newkey])
  result = (await r.readInteger()) == 1

proc ttl*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the time to live for a key
  await r.sendCommand("TTL", key)
  return await r.readInteger()

proc keyType*(r: Redis, key: string): RedisStatus =
  ## Determine the type stored at key
  r.sendCommand("TYPE", key)
  result = r.readStatus()


# Strings

proc append*(r: Redis | AsyncRedis, key, value: string): Future[RedisInteger] {.multisync.} =
  ## Append a value to a key
  await r.sendCommand("APPEND", key, @[value])
  result = await r.readInteger()

proc decr*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Decrement the integer value of a key by one
  await r.sendCommand("DECR", key)
  result = await r.readInteger()

proc decrBy*(r: Redis | AsyncRedis, key: string, decrement: int): Future[RedisInteger] {.multisync.} =
  ## Decrement the integer value of a key by the given number
  await r.sendCommand("DECRBY", key, @[$decrement])
  result = await r.readInteger()

proc mget*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Get the values of all given keys
  await r.sendCommand("MGET", keys)
  result = await r.readArray()

proc get*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Get the value of a key. Returns `redisNil` when `key` doesn't exist.
  await r.sendCommand("GET", key)
  result = await r.readBulkString()

#TODO: BITOP
proc getBit*(r: Redis | AsyncRedis, key: string, offset: int): Future[RedisInteger] {.multisync.} =
  ## Returns the bit value at offset in the string value stored at key
  await r.sendCommand("GETBIT", key, @[$offset])
  result = await r.readInteger()

proc bitCount*(r: Redis | AsyncRedis, key: string, limits: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Returns the number of set bits, optionally within limits
  await r.sendCommand("BITCOUNT", key, limits)
  result = await r.readInteger()

proc bitPos*(r: Redis | AsyncRedis, key: string, bit: int, limits: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Returns position of the first occurence of bit within limits
  var parameters = newSeqOfCap[string](len(limits) + 1)
  parameters.add($bit)
  parameters.add(limits)

  await r.sendCommand("BITPOS", key, parameters)
  result = await r.readInteger()

proc getRange*(r: Redis | AsyncRedis, key: string, start, stop: int): Future[RedisString] {.multisync.} =
  ## Get a substring of the string stored at a key
  await r.sendCommand("GETRANGE", key, @[$start, $stop])
  result = await r.readBulkString()

proc getSet*(r: Redis | AsyncRedis, key: string, value: string): Future[RedisString] {.multisync.} =
  ## Set the string value of a key and return its old value. Returns `redisNil`
  ## when key doesn't exist.
  await r.sendCommand("GETSET", key, @[value])
  result = await r.readBulkString()

proc incr*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Increment the integer value of a key by one.
  await r.sendCommand("INCR", key)
  result = await r.readInteger()

proc incrBy*(r: Redis | AsyncRedis, key: string, increment: int): Future[RedisInteger] {.multisync.} =
  ## Increment the integer value of a key by the given number
  await r.sendCommand("INCRBY", key, @[$increment])
  result = await r.readInteger()

#TODO incrbyfloat

proc msetk*(
  r: Redis | AsyncRedis,
  keyValues: seq[tuple[key, value: string]]
): Future[void] {.multisync.} =
  ## Set mupltiple keys to multplie values
  var args: seq[string] = @[]
  for key, value in items(keyValues):
    args.add(key)
    args.add(value)
  await r.sendCommand("MSET", args)
  raiseNoOK(r, await r.readStatus())

proc setk*(r: Redis | AsyncRedis, key, value: string): Future[void] {.multisync.} =
  ## Set the string value of a key.
  ##
  ## NOTE: This function had to be renamed due to a clash with the `set` type.
  await r.sendCommand("SET", key, @[value])
  raiseNoOK(r, await r.readStatus())

proc setNX*(r: Redis | AsyncRedis, key, value: string): Future[bool] {.multisync.} =
  ## Set the value of a key, only if the key does not exist. Returns `true`
  ## if the key was set.
  await r.sendCommand("SETNX", key, @[value])
  result = (await r.readInteger()) == 1

proc setBit*(r: Redis | AsyncRedis, key: string, offset: int,
             value: string): Future[RedisInteger] {.multisync.} =
  ## Sets or clears the bit at offset in the string value stored at key
  await r.sendCommand("SETBIT", key, @[$offset, value])
  result = await r.readInteger()

proc setEx*(r: Redis | AsyncRedis, key: string, seconds: int, value: string): Future[RedisStatus] {.multisync.} =
  ## Set the value and expiration of a key
  await r.sendCommand("SETEX", key, @[$seconds, value])
  raiseNoOK(r, await r.readStatus())

proc setRange*(r: Redis | AsyncRedis, key: string, offset: int,
               value: string): Future[RedisInteger] {.multisync.} =
  ## Overwrite part of a string at key starting at the specified offset
  await r.sendCommand("SETRANGE", key, @[$offset, value])
  result = await r.readInteger()

proc strlen*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the length of the value stored in a key. Returns 0 when key doesn't
  ## exist.
  await r.sendCommand("STRLEN", key)
  result = await r.readInteger()

# Hashes
proc hDel*(r: Redis | AsyncRedis, key, field: string): Future[bool] {.multisync.} =
  ## Delete a hash field at `key`. Returns `true` if the field was removed.
  await r.sendCommand("HDEL", key, @[field])
  result = (await r.readInteger()) == 1

proc hExists*(r: Redis | AsyncRedis, key, field: string): Future[bool] {.multisync.} =
  ## Determine if a hash field exists.
  await r.sendCommand("HEXISTS", key, @[field])
  result = (await r.readInteger()) == 1

proc hGet*(r: Redis | AsyncRedis, key, field: string): Future[RedisString] {.multisync.} =
  ## Get the value of a hash field
  await r.sendCommand("HGET", key, @[field])
  result = await r.readBulkString()

proc hGetAll*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the fields and values in a hash
  await r.sendCommand("HGETALL", key)
  result = await r.readArray()

proc hIncrBy*(r: Redis | AsyncRedis, key, field: string, incr: int): Future[RedisInteger] {.multisync.} =
  ## Increment the integer value of a hash field by the given number
  await r.sendCommand("HINCRBY", key, @[field, $incr])
  result = await r.readInteger()

proc hKeys*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the fields in a hash
  await r.sendCommand("HKEYS", key)
  result = await r.readArray()

proc hLen*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the number of fields in a hash
  await r.sendCommand("HLEN", key)
  result = await r.readInteger()

proc hMGet*(r: Redis | AsyncRedis, key: string, fields: seq[string]): Future[RedisList] {.multisync.} =
  ## Get the values of all the given hash fields
  await r.sendCommand("HMGET", key, fields)
  result = await r.readArray()

proc hMSet*(r: Redis | AsyncRedis, key: string,
            fieldValues: seq[tuple[field, value: string]]): Future[void] {.multisync.} =
  ## Set multiple hash fields to multiple values
  var args = @[key]
  for field, value in items(fieldValues):
    args.add(field)
    args.add(value)
  await r.sendCommand("HMSET", args)
  raiseNoOK(r, await r.readStatus())

proc hSet*(r: Redis | AsyncRedis, key, field, value: string): Future[RedisInteger] {.multisync.} =
  ## Set the string value of a hash field
  await r.sendCommand("HSET", key, @[field, value])
  result = await r.readInteger()

proc hSetNX*(r: Redis | AsyncRedis, key, field, value: string): Future[RedisInteger] {.multisync.} =
  ## Set the value of a hash field, only if the field does **not** exist
  await r.sendCommand("HSETNX", key, @[field, value])
  result = await r.readInteger()

proc hVals*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the values in a hash
  await r.sendCommand("HVALS", key)
  result = await r.readArray()

# Lists

proc bLPop*(r: Redis | AsyncRedis, keys: seq[string], timeout: int): Future[RedisList] {.multisync.} =
  ## Remove and get the *first* element in a list, or block until
  ## one is available
  var args = newSeqOfCap[string](len(keys) + 1)
  for i in items(keys):
    args.add(i)

  args.add($timeout)

  await r.sendCommand("BLPOP", args)
  result = await r.readArray()

proc bRPop*(r: Redis | AsyncRedis, keys: seq[string], timeout: int): Future[RedisList] {.multisync.} =
  ## Remove and get the *last* element in a list, or block until one
  ## is available.
  var args = newSeqOfCap[string](len(keys) + 1)
  for i in items(keys):
    args.add(i)

  args.add($timeout)

  await r.sendCommand("BRPOP", args)
  result = await r.readArray()

proc bRPopLPush*(r: Redis | AsyncRedis, source, destination: string,
                 timeout: int): Future[RedisString] {.multisync.} =
  ## Pop a value from a list, push it to another list and return it; or
  ## block until one is available.
  ##
  ## http://redis.io/commands/brpoplpush
  await r.sendCommand("BRPOPLPUSH", source, @[destination, $timeout])
  result = await r.readBulkString(true) # Multi-Bulk nil allowed.

proc lIndex*(r: Redis | AsyncRedis, key: string, index: int): Future[RedisString]  {.multisync.} =
  ## Get an element from a list by its index
  await r.sendCommand("LINDEX", key, @[$index])
  result = await r.readBulkString()

proc lInsert*(r: Redis | AsyncRedis, key: string, before: bool, pivot, value: string):
              Future[RedisInteger] {.multisync.} =
  ## Insert an element before or after another element in a list
  var pos = if before: "BEFORE" else: "AFTER"
  await r.sendCommand("LINSERT", key, @[pos, pivot, value])
  result = await r.readInteger()

proc lLen*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the length of a list
  await r.sendCommand("LLEN", key)
  result = await r.readInteger()

proc lPop*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Remove and get the first element in a list
  await r.sendCommand("LPOP", key)
  result = await r.readBulkString()

proc lPush*(r: Redis | AsyncRedis, key, value: string, create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Prepend a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `LPUSH`
  ## will be used, otherwise `LPUSHX`.
  if create:
    await r.sendCommand("LPUSH", key, @[value])
  else:
    await r.sendCommand("LPUSHX", key, @[value])

  result = await r.readInteger()

proc lLPush*(r: Redis | AsyncRedis, key: string, values: seq[string], create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Append a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `RPUSH`
  ## will be used, otherwise `RPUSHX`.
  if create:
    await r.sendCommand("LPUSH", key, values)
  else:
    await r.sendCommand("LPUSHX", key, values)

  result = await r.readInteger()

proc lRange*(r: Redis | AsyncRedis, key: string, start, stop: int): Future[RedisList] {.multisync.} =
  ## Get a range of elements from a list.
  await r.sendCommand("LRANGE", key, @[$start, $stop])
  result = await r.readArray()

proc lRem*(r: Redis | AsyncRedis, key: string, value: string, count: int = 0): Future[RedisInteger] {.multisync.} =
  ## Remove elements from a list. Returns the number of elements that have been
  ## removed.
  await r.sendCommand("LREM", key, @[$count, value])
  result = await r.readInteger()

proc lSet*(r: Redis | AsyncRedis, key: string, index: int, value: string): Future[void] {.multisync.} =
  ## Set the value of an element in a list by its index
  await r.sendCommand("LSET", key, @[$index, value])
  raiseNoOK(r, await r.readStatus())

proc lTrim*(r: Redis | AsyncRedis, key: string, start, stop: int): Future[void] {.multisync.}  =
  ## Trim a list to the specified range
  await r.sendCommand("LTRIM", key, @[$start, $stop])
  raiseNoOK(r, await r.readStatus())

proc rPop*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Remove and get the last element in a list
  await r.sendCommand("RPOP", key)
  result = await r.readBulkString()

proc rPopLPush*(r: Redis | AsyncRedis, source, destination: string): Future[RedisString] {.multisync.} =
  ## Remove the last element in a list, append it to another list and return it
  await r.sendCommand("RPOPLPUSH", source, @[destination])
  result = await r.readBulkString()

proc rPush*(r: Redis | AsyncRedis, key, value: string, create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Append a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `RPUSH`
  ## will be used, otherwise `RPUSHX`.
  if create:
    await r.sendCommand("RPUSH", key, @[value])
  else:
    await r.sendCommand("RPUSHX", key, @[value])

  result = await r.readInteger()

proc rLPush*(r: Redis | AsyncRedis, key: string, values: seq[string], create: bool = true): Future[RedisInteger] {.multisync.} =
  ## Append a value to a list. Returns the length of the list after the push.
  ## The ``create`` param specifies whether a list should be created if it
  ## doesn't exist at ``key``. More specifically if ``create`` is true, `RPUSH`
  ## will be used, otherwise `RPUSHX`.
  if create:
    await r.sendCommand("RPUSH", key, values)
  else:
    await r.sendCommand("RPUSHX", key, values)

  result = await r.readInteger()

# Sets

proc sadd*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Add a member to a set
  await r.sendCommand("SADD", key, @[member])
  result = await r.readInteger()

proc sladd*(r: Redis | AsyncRedis, key: string, members: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add a member to a set
  await r.sendCommand("SADD", key, members)
  result = await r.readInteger()

proc scard*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the number of members in a set
  await r.sendCommand("SCARD", key)
  result = await r.readInteger()

proc sdiff*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Subtract multiple sets
  await r.sendCommand("SDIFF", keys)
  result = await r.readArray()

proc sdiffstore*(r: Redis | AsyncRedis, destination: string,
                keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Subtract multiple sets and store the resulting set in a key
  await r.sendCommand("SDIFFSTORE", destination, keys)
  result = await r.readInteger()

proc sinter*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Intersect multiple sets
  await r.sendCommand("SINTER", keys)
  result = await r.readArray()

proc sinterstore*(r: Redis | AsyncRedis, destination: string,
                 keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Intersect multiple sets and store the resulting set in a key
  await r.sendCommand("SINTERSTORE", destination, keys)
  result = await r.readInteger()

proc sismember*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Determine if a given value is a member of a set
  await r.sendCommand("SISMEMBER", key, @[member])
  result = await r.readInteger()

proc smembers*(r: Redis | AsyncRedis, key: string): Future[RedisList] {.multisync.} =
  ## Get all the members in a set
  await r.sendCommand("SMEMBERS", key)
  result = await r.readArray()

proc smove*(r: Redis | AsyncRedis, source: string, destination: string,
           member: string): Future[RedisInteger] {.multisync.} =
  ## Move a member from one set to another
  await r.sendCommand("SMOVE", source, @[destination, member])
  result = await r.readInteger()

proc spop*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Remove and return a random member from a set
  await r.sendCommand("SPOP", key)
  result = await r.readBulkString()

proc srandmember*(r: Redis | AsyncRedis, key: string): Future[RedisString] {.multisync.} =
  ## Get a random member from a set
  await r.sendCommand("SRANDMEMBER", key)
  result = await r.readBulkString()

proc srem*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Remove a member from a set
  await r.sendCommand("SREM", key, @[member])
  result = await r.readInteger()

proc sunion*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisList] {.multisync.} =
  ## Add multiple sets
  await r.sendCommand("SUNION", keys)
  result = await r.readArray()

proc sunionstore*(r: Redis | AsyncRedis, destination: string,
                 key: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add multiple sets and store the resulting set in a key
  await r.sendCommand("SUNIONSTORE", destination, key)
  result = await r.readInteger()

# Sorted sets

proc zadd*(r: Redis | AsyncRedis, key: string, score: int, member: string): Future[RedisInteger] {.multisync.} =
  ## Add a member to a sorted set, or update its score if it already exists
  await r.sendCommand("ZADD", key, @[$score, member])
  result = await r.readInteger()

proc zcard*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Get the number of members in a sorted set
  await r.sendCommand("ZCARD", key)
  result = await r.readInteger()

proc zcount*(r: Redis | AsyncRedis, key: string, min: string, max: string): Future[RedisInteger] {.multisync.} =
  ## Count the members in a sorted set with scores within the given values
  await r.sendCommand("ZCOUNT", key, @[min, max])
  result = await r.readInteger()

proc zincrby*(r: Redis | AsyncRedis, key: string, increment: string,
             member: string): Future[RedisString] {.multisync.}  =
  ## Increment the score of a member in a sorted set
  await r.sendCommand("ZINCRBY", key, @[increment, member])
  result = await r.readBulkString()

proc zinterstore*(r: Redis | AsyncRedis, destination: string, numkeys: string,
                 keys: seq[string], weights: seq[string] = @[],
                 aggregate: string = ""): Future[RedisInteger] {.multisync.} =
  ## Intersect multiple sorted sets and store the resulting sorted set in
  ## a new key
  let argsLen = 2 + len(keys) + (if len(weights) > 0: len(weights) + 1 else: 0) + (if len(aggregate) > 0: 1 + len(aggregate) else: 0)
  var args = newSeqOfCap[string](argsLen)

  args.add(destination)
  args.add(numkeys)

  for i in items(keys):
    args.add(i)

  if weights.len != 0:
    args.add("WEIGHTS")
    for i in items(weights):
      args.add(i)

  if aggregate.len != 0:
    args.add("AGGREGATE")
    args.add(aggregate)

  await r.sendCommand("ZINTERSTORE", args)

  result = await r.readInteger()

proc zrange*(r: Redis | AsyncRedis, key: string, start: string, stop: string,
            withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by index
  if not withScores:
    await r.sendCommand("ZRANGE", key, @[start, stop])
  else:
    await r.sendCommand("ZRANGE", key, @[start, stop, "WITHSCORES"])

  result = await r.readArray()

proc zrangebyscore*(r: Redis | AsyncRedis, key: string, min: string, max: string,
                   withScores: bool = false, limit: bool = false,
                   limitOffset: int = 0, limitCount: int = 0): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by score
  var args = newSeqOfCap[string](3 + (if withScores: 1 else: 0) + (if limit: 3 else: 0))
  args.add(key)
  args.add(min)
  args.add(max)

  if withScores: args.add("WITHSCORES")
  if limit:
    args.add("LIMIT")
    args.add($limitOffset)
    args.add($limitCount)

  await r.sendCommand("ZRANGEBYSCORE", args)
  result = await r.readArray()

proc zrangebylex*(r: Redis | AsyncRedis, key: string, start: string, stop: string,
                  limit: bool = false, limitOffset: int = 0,
                  limitCount: int = 0): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, ordered lexicographically
  var args = newSeqOfCap[string](3 + (if limit: 3 else: 0))
  args.add(key)
  args.add(start)
  args.add(stop)
  if limit:
    args.add("LIMIT")
    args.add($limitOffset)
    args.add($limitCount)

  await r.sendCommand("ZRANGEBYLEX", args)
  result = await r.readArray()

proc zrank*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisString] {.multisync.} =
  ## Determine the index of a member in a sorted set
  await r.sendCommand("ZRANK", key, @[member])
  try:
    result = $(await r.readInteger())
  except ReplyError:
    result = redisNil

proc zrem*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisInteger] {.multisync.} =
  ## Remove a member from a sorted set
  await r.sendCommand("ZREM", key, @[member])
  result = await r.readInteger()

proc zremrangebyrank*(r: Redis | AsyncRedis, key: string, start: string,
                     stop: string): Future[RedisInteger] {.multisync.} =
  ## Remove all members in a sorted set within the given indexes
  await r.sendCommand("ZREMRANGEBYRANK", key, @[start, stop])
  result = await r.readInteger()

proc zremrangebyscore*(r: Redis | AsyncRedis, key: string, min: string,
                      max: string): Future[RedisInteger] {.multisync.} =
  ## Remove all members in a sorted set within the given scores
  await r.sendCommand("ZREMRANGEBYSCORE", key, @[min, max])
  result = await r.readInteger()

proc zrevrange*(r: Redis | AsyncRedis, key: string, start: string, stop: string,
               withScores: bool = false): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by index,
  ## with scores ordered from high to low
  if withScores:
    await r.sendCommand("ZREVRANGE", key, @[start, stop, "WITHSCORES"])
  else:
    await r.sendCommand("ZREVRANGE", key, @[start, stop])

  result = await r.readArray()

proc zrevrangebyscore*(r: Redis | AsyncRedis, key: string, min: string, max: string,
                   withScores: bool = false, limit: bool = false,
                   limitOffset: int = 0, limitCount: int = 0): Future[RedisList] {.multisync.} =
  ## Return a range of members in a sorted set, by score, with
  ## scores ordered from high to low
  var args = newSeqOfCap[string](3 + (if withScores: 1 else: 0) + (if limit: 3 else: 0))
  args.add(key)
  args.add(min)
  args.add(max)

  if withScores: args.add("WITHSCORES")
  if limit:
    args.add("LIMIT")
    args.add($limitOffset)
    args.add($limitCount)

  await r.sendCommand("ZREVRANGEBYSCORE", args)
  result = await r.readArray()

proc zrevrank*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisString] {.multisync.} =
  ## Determine the index of a member in a sorted set, with
  ## scores ordered from high to low
  await r.sendCommand("ZREVRANK", key, @[member])
  try:
    result = $(await r.readInteger())
  except ReplyError:
    result = redisNil

proc zscore*(r: Redis | AsyncRedis, key: string, member: string): Future[RedisString] {.multisync.} =
  ## Get the score associated with the given member in a sorted set
  await r.sendCommand("ZSCORE", key, @[member])
  result = await r.readBulkString()

proc zunionstore*(r: Redis | AsyncRedis, destination: string, numkeys: string,
                 keys: seq[string], weights: seq[string] = @[],
                 aggregate: string = ""): Future[RedisInteger] {.multisync.} =
  ## Add multiple sorted sets and store the resulting sorted set in a new key
  var args = newSeqOfCap[string](2 + len(keys) + (if len(weights) > 0: 1 + len(weights) else: 0) + (if len(aggregate) > 0: 1 + len(aggregate) else: 0))
  args.add(destination)
  args.add(numkeys)

  for i in items(keys):
    args.add(i)

  if weights.len != 0:
    args.add("WEIGHTS")
    for i in items(weights): args.add(i)

  if aggregate.len != 0:
    args.add("AGGREGATE")
    args.add(aggregate)

  await r.sendCommand("ZUNIONSTORE", args)

  result = await r.readInteger()

# HyperLogLog

proc pfadd*(r: Redis | AsyncRedis, key: string, elements: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Add variable number of elements into special 'HyperLogLog' set type
  await r.sendCommand("PFADD", key, elements)
  result = await r.readInteger()

proc pfcount*(r: Redis | AsyncRedis, key: string): Future[RedisInteger] {.multisync.} =
  ## Count approximate number of elements in 'HyperLogLog'
  await r.sendCommand("PFCOUNT", key)
  result = await r.readInteger()

proc pfcount*(r: Redis | AsyncRedis, keys: seq[string]): Future[RedisInteger] {.multisync.} =
  ## Count approximate number of elements in 'HyperLogLog'
  await r.sendCommand("PFCOUNT", keys)
  result = await r.readInteger()

proc pfmerge*(r: Redis | AsyncRedis, destination: string, sources: seq[string]): Future[void] {.multisync.} =
  ## Merge several source HyperLogLog's into one specified by destKey
  await r.sendCommand("PFMERGE", destination, sources)
  raiseNoOK(r, await r.readStatus())

# Pub/Sub

proc pubsub*(c: AsyncValkey; ignoreSubscribeMessages=false): AsyncPubSub =
  new(result)
  result.params = c.params
  result.conn = nil # lazy
  result.ignoreSubscribeMessages = ignoreSubscribeMessages

  result.channels = initHashSet[string]()
  result.patterns = initHashSet[string]()
  result.shardChannels = initHashSet[string]()

  result.pendingUnsubChannels = initHashSet[string]()
  result.pendingUnsubPatterns = initHashSet[string]()
  result.pendingUnsubShardChannels = initHashSet[string]()

  result.subscribed = false
  result.subscribedFut = newFuture[void]("pubsub.subscribed")

proc resetState(ps: AsyncPubSub)
proc close*(ps: AsyncPubSub): Future[void] {.async.}  # <-- add this forward decl
proc requireConn(ps: AsyncPubSub): void =
  ## Ensure that the Pub/Sub instance has a valid connection
  if ps.conn.isNil:
    raisePubSubError("pubsub connection not set: call subscribe/psubscribe/ping first")

proc connectValkeyAsync*(host = "localhost", port = 6379.Port, db = 0,
                        username = "", password = ""): Future[AsyncValkey]

proc ensureConn(ps: AsyncPubSub): Future[void] {.async.} =
  ## Lazily create a AsyncValkey connection for the Pub/Sub instance
  if ps.conn.isNil:
    ps.conn = await connectValkeyAsync(
      host = ps.params.host,
      port = ps.params.port,
      db = ps.params.db,
      username = ps.params.username,
      password = ps.params.password
    )
    ps.conn.pipeline.enabled = false
    ps.conn.pipeline.expected = 0

proc encodeRespArray(argv: openArray[string]): string =
  ## Encode argv as RESP2 Array of bulk strings
  ## e.g. ["PING", "hello"] -> "*2\r\n$4\r\nPING\r\n$5\r\nhello\r\n"
  doAssert argv.len > 0
  result = "*" & $argv.len & "\c\L"
  for arg in argv:
    result.add("$" & $arg.len & "\c\L")
    result.add(arg & "\c\L")

proc executeCommandImpl(ps: AsyncPubSub; argv: seq[string]): Future[void] {.async.} =
  let req = encodeRespArray(argv)
  await ps.ensureConn()
  # IMPORTANT: bypass managedSend/SendCommand to avoid currentCommand/finalise coupling.
  try:
    await ps.conn.sendRaw(req) # send-only, no reads, no managedSend
  except CatchableError as e:
    if not ps.conn.isNil:
      try:
        ps.conn.socket.close()
      except ConnectionError:
        discard
      ps.conn = nil
    ps.resetState()
    raiseConnError("pubsub send failed: " & e.msg)

proc executeCommand(ps: AsyncPubSub; argv: openArray[string]): Future[void] =
  # Execute with argv as is
  return ps.executeCommandImpl(@argv)

proc executeCommand(ps: AsyncPubSub; cmd: string; args: varargs[string]): Future[void] =
  # Construct argv from cmd + args
  var argv: seq[string] = @[cmd]
  for a in args: argv.add a
  return ps.executeCommandImpl(argv)

# TODO: consider adding 'subscribeWaitAcks' that waits for server acks
proc waitSubscribed*(ps: AsyncPubSub): Future[void] =
  ## Completes once the pubsub instance has at least one active subscription
  ## Resets with new future when subscriptions drop back to zero.
  ps.subscribedFut

proc updateSubscribed(ps: AsyncPubSub): void =
  # check for active subscription
  let now = ps.channels.len > 0 or ps.patterns.len > 0 or ps.shardChannels.len > 0
  # if the current state is the same as the saved state, no change
  if now == ps.subscribed:
    return
  ps.subscribed = now # update state
  # complete or reset future
  if now:
    if not ps.subscribedFut.finished:
      ps.subscribedFut.complete()
  else:
    ps.subscribedFut = newFuture[void]("pubsub.subscribed")

proc normalizeTargets(xs: seq[string]; cmdName: string): seq[string] =
  result = xs.deduplicate()
  if result.len == 0:
    raise newException(ValueError, cmdName & " needs at least one target")

proc subscribeImpl(ps: AsyncPubSub; channels: seq[string]): Future[void] {.async.}  =
  let uniqueChannels = normalizeTargets(channels, "SUBSCRIBE")

  var argv = newSeqOfCap[string](1 + uniqueChannels.len)
  argv.add "SUBSCRIBE"
  for c in uniqueChannels: argv.add c

  await ps.executeCommand(argv)

  for c in uniqueChannels:
    ps.channels.incl(c)
    ps.pendingUnsubChannels.excl(c)

proc subscribe*(ps: AsyncPubSub; channels: varargs[string]): Future[void] =
  return ps.subscribeImpl(@channels)

proc psubscribeImpl(ps: AsyncPubSub; patterns: seq[string]): Future[void] {.async.}  =
  let uniquePatterns = normalizeTargets(patterns, "PSUBSCRIBE")

  var argv = newSeqOfCap[string](1 + uniquePatterns.len)
  argv.add "PSUBSCRIBE"
  for p in uniquePatterns: argv.add p

  await ps.executeCommand(argv)

  for p in uniquePatterns:
    ps.patterns.incl(p)
    ps.pendingUnsubPatterns.excl(p)

proc psubscribe*(ps: AsyncPubSub; pattern: varargs[string]): Future[void] =
  return ps.psubscribeImpl(@pattern)

proc ssubscribeImpl(ps: AsyncPubSub; channels: seq[string]): Future[void] {.async.}  =
  let uniqueChannels = normalizeTargets(channels, "SSUBSCRIBE")

  var argv = newSeqOfCap[string](1 + uniqueChannels.len)
  argv.add "SSUBSCRIBE"
  for c in uniqueChannels: argv.add c

  await ps.executeCommand(argv)

  for c in uniqueChannels:
    ps.shardChannels.incl(c)
    ps.pendingUnsubShardChannels.excl(c)

proc ssubscribe*(ps: AsyncPubSub; channels: varargs[string]): Future[void] =
  return ps.ssubscribeImpl(@channels)

proc unsubscribe*(ps: AsyncPubSub; channels: varargs[string]): Future[void] =
  if channels.len == 0:
    # unsubscribe from all currently known channels
    for c in ps.channels:
      ps.pendingUnsubChannels.incl(c)
    return ps.executeCommand("UNSUBSCRIBE")

  let uniq = normalizeTargets(@channels, "UNSUBSCRIBE")
  for c in uniq:
    ps.pendingUnsubChannels.incl(c)

  var argv = newSeqOfCap[string](1 + uniq.len)
  argv.add "UNSUBSCRIBE"
  for c in uniq: argv.add c
  return ps.executeCommand(argv)

proc punsubscribe*(ps: AsyncPubSub; patterns: varargs[string]): Future[void] =
  if patterns.len == 0:
    for p in ps.patterns:
      ps.pendingUnsubPatterns.incl(p)
    return ps.executeCommand("PUNSUBSCRIBE")

  let uniq = normalizeTargets(@patterns, "PUNSUBSCRIBE")
  for p in uniq:
    ps.pendingUnsubPatterns.incl(p)

  var argv = newSeqOfCap[string](1 + uniq.len)
  argv.add "PUNSUBSCRIBE"
  for p in uniq: argv.add p
  return ps.executeCommand(argv)

proc sunsubscribe*(ps: AsyncPubSub; channels: varargs[string]): Future[void] =
  if channels.len == 0:
    for c in ps.shardChannels:
      ps.pendingUnsubShardChannels.incl(c)
    return ps.executeCommand("SUNSUBSCRIBE")

  let uniq = normalizeTargets(@channels, "SUNSUBSCRIBE")
  for c in uniq:
    ps.pendingUnsubShardChannels.incl(c)

  var argv = newSeqOfCap[string](1 + uniq.len)
  argv.add "SUNSUBSCRIBE"
  for c in uniq: argv.add c
  return ps.executeCommand(argv)

proc parseResponse*(ps: AsyncPubSub): Future[RedisList] {.async.} =
  ps.requireConn()
  try:
    return await ps.conn.readPubSubFrame()
  except ConnectionError, ProtocolError:
    try:
      await ps.close()
    except CatchableError:
      discard
    raise

proc stringToKind(s: string): PubSubEventKind =
  case s.toLowerAscii()
  of "subscribe":    pekSubscribe
  of "unsubscribe":  pekUnsubscribe
  of "psubscribe":   pekPSubscribe
  of "punsubscribe": pekPUnsubscribe
  of "ssubscribe":   pekSSubscribe
  of "sunsubscribe": pekSUnsubscribe
  of "message":      pekMessage
  of "pmessage":     pekPMessage
  of "smessage":     pekSMessage
  of "pong":         pekPong
  else:              pekUnknown

proc parseEvent*(response: openArray[string]): Option[PubSubEvent] =
  if response.len == 0: return none(PubSubEvent)

  let kind = stringToKind(response[0])
  var event = PubSubEvent(kind: kind, count: -1)

  case kind
  of pekPMessage:
    # ["pmessage", pattern, channel, data]
    if response.len != 4: return none(PubSubEvent)
    event.pattern = response[1]
    event.channel = response[2]
    event.data = response[3]
    return some(event)

  of pekMessage, pekSMessage:
    # ["message"|"smessage", channel, data]
    if response.len != 3: return none(PubSubEvent)
    event.channel = response[1]
    event.data = response[2]
    return some(event)

  of pekPong:
    # ["pong"] / ["PONG"] or ["pong", data]
    if response.len == 1:
      event.data = ""
      return some(event)
    if response.len != 2: return none(PubSubEvent)
    event.data = response[1]
    return some(event)

  of pekPSubscribe, pekPUnsubscribe:
    # ["psubscribe"|"punsubscribe", pattern, count]
    if response.len != 3: return none(PubSubEvent)
    event.pattern = response[1]
    try:
      event.count = parseInt(response[2])
    except ValueError:
      return none(PubSubEvent)
    return some(event)

  of pekSubscribe, pekUnsubscribe, pekSSubscribe, pekSUnsubscribe:
    # ["subscribe"|"unsubscribe"|"ssubscribe"|"sunsubscribe", channel, count]
    if response.len != 3: return none(PubSubEvent)
    event.channel = response[1]
    try:
      event.count = parseInt(response[2])
    except ValueError:
      return none(PubSubEvent)
    return some(event)

  else:
    return none(PubSubEvent) # TODO: figure out what to do with "unknown" events. Maybe return an event with kind pekUnknown with channel/data...

proc subKey(ev: PubSubEvent): string =
  if ev.pattern.len > 0: ev.pattern else: ev.channel

proc applyState(ps: AsyncPubSub; ev: PubSubEvent): void =
  let key = subKey(ev)
  if key.len == 0: return

  case ev.kind
  of pekSubscribe:
    ps.channels.incl(key)
    ps.pendingUnsubChannels.excl(key)
    ps.updateSubscribed()

  of pekUnsubscribe:
    ps.channels.excl(key)
    ps.pendingUnsubChannels.excl(key)
    ps.updateSubscribed()

  of pekPSubscribe:
    ps.patterns.incl(key)
    ps.pendingUnsubPatterns.excl(key)
    ps.updateSubscribed()

  of pekPUnsubscribe:
    ps.patterns.excl(key)
    ps.pendingUnsubPatterns.excl(key)
    ps.updateSubscribed()

  of pekSSubscribe:
    ps.shardChannels.incl(key)
    ps.pendingUnsubShardChannels.excl(key)
    ps.updateSubscribed()

  of pekSUnsubscribe:
    ps.shardChannels.excl(key)
    ps.pendingUnsubShardChannels.excl(key)
    ps.updateSubscribed()

  else:
    # no state change for other event kinds
    discard

proc handleMessage*(ps: AsyncPubSub; frame: RedisList; ignoreSubscribeMessages=false): Option[PubSubEvent] =
  if frame.len == 0: return none(PubSubEvent)

  let eventOpt = parseEvent(frame)

  # Scalar replies (non-subscribed PING) arrive as @["..."]
  if eventOpt.isNone:
    if not ps.subscribed and ps.pendingPing > 0 and frame.len == 1:
      dec ps.pendingPing
      let s = frame[0]
      if s.cmpIgnoreCase("PONG") == 0:
        return some(PubSubEvent(kind: pekPong, data: ""))
      else:
        return some(PubSubEvent(kind: pekPong, data: s))
    return none(PubSubEvent)

  let event = eventOpt.get()

  # Pubsub mode : ["pong"] or ["pong", data]
  if event.kind == pekPong and ps.pendingPing > 0:
    dec ps.pendingPing

  let isSubCtl = event.kind in {
     pekSubscribe, pekUnsubscribe,
     pekPSubscribe, pekPUnsubscribe,
     pekSSubscribe, pekSUnsubscribe
  }
  if isSubCtl:
    ps.applyState(event)

  if isSubCtl and (ignoreSubscribeMessages or ps.ignoreSubscribeMessages):
    return none(PubSubEvent)
  return some(event)

proc receiveEvent*(ps: AsyncPubSub; ignoreSubscribeMessages=false): Future[PubSubEvent] {.async.} =
  # raise error if connection is None
  while true:
    let frame = await ps.parseResponse()
    let eventOpt = ps.handleMessage(frame, ignoreSubscribeMessages)
    if eventOpt.isSome:
      return eventOpt.get()

proc receiveMessage*(ps: AsyncPubSub; ignoreSubscribeMessages=false): Future[PubSubEvent] {.async.} =
  while true:
    let event = await ps.receiveEvent(ignoreSubscribeMessages=ignoreSubscribeMessages)
    if event.kind in {pekMessage, pekPMessage, pekSMessage}:
      return event

# proc psubscribe*(r: Redis, pattern: openarray[string]): ???? =
#   ## Listen for messages published to channels matching the given patterns
#   r.socket.send("PSUBSCRIBE $#\c\L" % pattern)
#   return ???

proc publish*(r: Redis | AsyncRedis, channel: string, message: string): Future[RedisInteger] {.multisync.} =
  ## Post a message to a channel
  await r.sendCommand("PUBLISH", channel, @[message])
  result = await r.readInteger()

# proc punsubscribe*(r: Redis, [pattern: openarray[string], : string): ???? =
#   ## Stop listening for messages posted to channels matching the given patterns
#   r.socket.send("PUNSUBSCRIBE $# $#\c\L" % [[pattern.join(), ])
#   return ???

proc subscribe*(r: AsyncRedis, channel: string) {.async.} =
  ## Listen for messages published to the given channel
  await r.sendCommand("SUBSCRIBE", @[channel])
  discard await r.readNext()
  finaliseCommand(r)

proc subscribe*(r: AsyncRedis, channels: seq[string]) {.async.} =
  ## Listen for messages published to the given channels
  await r.sendCommand("SUBSCRIBE", channels)
  for _ in channels:
    discard await r.readNext()
  finaliseCommand(r)

# proc unsubscribe*(r: Redis, [channel: openarray[string], : string): ???? =
#   ## Stop listening for messages posted to the given channels
#   r.socket.send("UNSUBSCRIBE $# $#\c\L" % [[channel.join(), ])
#   return ???

proc nextMessage*(r: AsyncRedis): Future[RedisMessage] {.async.} =
  let msg = await r.readNext()
  assert msg[0] == "message"
  result = RedisMessage()
  result.channel = msg[1]
  result.message = msg[2]

# Transactions

proc discardMulti*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Discard all commands issued after MULTI
  await r.sendCommand("DISCARD")
  raiseNoOK(r, await r.readStatus())

proc exec*(r: Redis | AsyncRedis): Future[RedisList] {.multisync.} =
  ## Execute all commands issued after MULTI
  await r.sendCommand("EXEC")
  r.pipeline.enabled = false
  # Will reply with +OK for MULTI/EXEC and +QUEUED for every command
  # between, then with the results
  result = await r.flushPipeline(true)

proc multi*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Mark the start of a transaction block
  r.startPipelining()
  await r.sendCommand("MULTI")
  raiseNoOK(r, await r.readStatus())

proc unwatch*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Forget about all watched keys
  await r.sendCommand("UNWATCH")
  raiseNoOK(r, await r.readStatus())

proc watch*(r: Redis | AsyncRedis, key: seq[string]): Future[void] {.multisync.} =
  ## Watch the given keys to determine execution of the MULTI/EXEC block
  await r.sendCommand("WATCH", key)
  raiseNoOK(r, await r.readStatus())

# Connection

proc auth*(r: Redis | AsyncRedis, password: string): Future[void] {.multisync.} =
  ## Authenticate to the server
  await r.sendCommand("AUTH", password)
  raiseNoOK(r, await r.readStatus())

proc auth*(r: Redis | AsyncRedis, username: string, password: string): Future[void] {.multisync.} =
  ## Authenticate to a server that uses Redis ACLs
  await r.sendCommand("AUTH", @[username, password])
  raiseNoOK(r, await r.readStatus())

proc echoServ*(r: Redis | AsyncRedis, message: string): Future[RedisString] {.multisync.} =
  ## Echo the given string
  await r.sendCommand("ECHO", message)
  result = await r.readBulkString()

proc ping*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Ping the server
  await r.sendCommand("PING")
  result = await r.readStatus()

proc ping*(ps: AsyncPubSub; payload = ""): Future[void] {.async.} =
  await ps.ensureConn()
  inc ps.pendingPing
  if payload.len == 0:
    await ps.executeCommand("PING")
  else:
    await ps.executeCommand("PING", payload)

proc resetState(ps: AsyncPubSub): void =
  ## Reset the Pub/Sub instance state
  ps.channels.clear()
  ps.patterns.clear()
  ps.shardChannels.clear()

  ps.pendingUnsubChannels.clear()
  ps.pendingUnsubPatterns.clear()
  ps.pendingUnsubShardChannels.clear()

  ps.subscribed = false

  if not ps.subscribedFut.finished:
    ps.subscribedFut.complete()

  ps.subscribedFut = newFuture[void]("pubsub.subscribed")
  ps.pendingPing = 0

proc close*(ps: AsyncPubSub): Future[void] {.async.} =
  ## Pub/Sub connection close (disconnect)
  if not ps.conn.isNil:
    ps.conn.socket.close()
    ps.conn = nil
  ps.resetState()

proc close*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Close the connection
  r.socket.close()

proc quit*(ps: AsyncPubSub): Future[void] {.async.} =
  ## Close the Pub/Sub connection with using QUIT command
  if ps.conn.isNil: return
  try:
    await ps.executeCommand("QUIT")
  except:
    discard
  ps.conn.socket.close()
  ps.conn = nil
  ps.resetState()

proc quit*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Close the connection with using QUIT command
  ## Note: This command is regarded as deprecated since Redis version 7.2.0.
  await r.sendCommand("QUIT")
  raiseNoOK(r, await r.readStatus())
  r.socket.close()

proc select*(r: Redis | AsyncRedis, index: int): Future[RedisStatus] {.multisync.} =
  ## Change the selected database for the current connection
  await r.sendCommand("SELECT", $index)
  result = await r.readStatus()

proc setupValkeyConnection*(v : Valkey | AsyncValkey, db = 0, username = "", password = ""): Future[void] {.multisync.} =
  ## Setup a valkey connection by authenticating and selecting the database
  if password.len > 0 and username.len > 0:
    await v.auth(username, password)
  elif password.len > 0:
    await v.auth(password)
  if db != 0:
    discard await v.select(db)

proc connectValkey*(host = "localhost", port = 6379.Port, db = 0, username = "", password = ""): Valkey =
  ## Open a synchronous connection to a valkey server.
  let v = open(host, port)
  v.setupValkeyConnection(db, username, password)
  result = v

proc connectValkeyUnix*(path = "/var/run/valkey/valkey-server.sock", db = 0, username = "", password = ""): Valkey =
  ## Open a synchronous unix connection to a valkey server.
  let v = openUnix(path)
  v.setupValkeyConnection(db, username, password)
  result = v

proc connectValkeyAsync*(host = "localhost", port = 6379.Port, db = 0, username = "", password = ""): Future[AsyncValkey] {.async.} =
  ## Open an asynchronous connection to a valkey server.
  let v = await openAsync(host, port)
  v.params = ValkeyConnParams(host: host, port: port, db: db, username: username, password: password)
  await v.setupValkeyConnection(db, username, password)
  result = v

proc connectValkeyUnixAsync*(path = "/var/run/valkey/valkey-server.sock", db = 0, username = "", password = ""): Future[AsyncValkey] {.async.} =
  ## Open an asynchronous unix connection to a valkey server.
  let v = await openUnixAsync(path)
  await v.setupValkeyConnection(db, username, password)
  result = v

# Server

proc bgrewriteaof*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Asynchronously rewrite the append-only file
  await r.sendCommand("BGREWRITEAOF")
  raiseNoOK(r, await r.readStatus())

proc bgsave*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Asynchronously save the dataset to disk
  await r.sendCommand("BGSAVE")
  raiseNoOK(r, await r.readStatus())

proc configGet*(r: Redis | AsyncRedis, parameter: string): Future[RedisList] {.multisync.} =
  ## Get the value of a configuration parameter
  await r.sendCommand("CONFIG", "GET", @[parameter])
  result = await r.readArray()

proc configSet*(r: Redis | AsyncRedis, parameter: string, value: string): Future[void] {.multisync.} =
  ## Set a configuration parameter to the given value
  await r.sendCommand("CONFIG", "SET", @[parameter, value])
  raiseNoOK(r, await r.readStatus())

proc configResetStat*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Reset the stats returned by INFO
  await r.sendCommand("CONFIG", "RESETSTAT")
  raiseNoOK(r, await r.readStatus())

proc dbsize*(r: Redis | AsyncRedis): Future[RedisInteger] {.multisync.} =
  ## Return the number of keys in the selected database
  await r.sendCommand("DBSIZE")
  result = await r.readInteger()

proc debugObject*(r: Redis | AsyncRedis, key: string): Future[RedisStatus] {.multisync.} =
  ## Get debugging information about a key
  await r.sendCommand("DEBUG", "OBJECT", @[key])
  result = await r.readStatus()

proc debugSegfault*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Make the server crash
  await r.sendCommand("DEBUG", "SEGFAULT")

proc flushall*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Remove all keys from all databases
  await r.sendCommand("FLUSHALL")
  raiseNoOK(r, await r.readStatus())

proc flushdb*(r: Redis | AsyncRedis): Future[RedisStatus] {.multisync.} =
  ## Remove all keys from the current database
  await r.sendCommand("FLUSHDB")
  raiseNoOK(r, await r.readStatus())

proc info*(r: Redis | AsyncRedis): Future[RedisString] {.multisync.} =
  ## Get information and statistics about the server
  await r.sendCommand("INFO")
  result = await r.readBulkString()

proc info*(r: Redis | AsyncRedis, section: string): Future[RedisString] {.multisync.} =
  ## Get information and statistics about the server
  await r.sendCommand("INFO", section)
  result = await r.readBulkString()

proc detectEngineKind(r: Valkey | AsyncValkey): Future[EngineKind] {.multisync.} =
  ## Internal helper to detect the engine kind based on INFO server
  let infoStr = await r.info("server")

  var kind = ekUnknown
  for rawLine in infoStr.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line[0] == '#':
      continue
    if line.startsWith("valkey_version:"):
      kind = ekValkey
    elif line.startsWith("redis_version:") and kind == ekUnknown:
      kind = ekRedis
  result = kind

proc isValkey*(v: Valkey | AsyncValkey): Future[bool] {.multisync.} =
  ## Check if the connected server is Valkey
  (await detectEngineKind(v)) == ekValkey

proc isRedis*(r: Valkey | AsyncValkey): Future[bool] {.multisync.} =
  ## Check if the connected server is Redis
  (await detectEngineKind(r)) == ekRedis

proc lastsave*(r: Redis | AsyncRedis): Future[RedisInteger] {.multisync.} =
  ## Get the UNIX time stamp of the last successful save to disk
  await r.sendCommand("LASTSAVE")
  result = await r.readInteger()

discard """
proc monitor*(r: Redis) =
  ## Listen for all requests received by the server in real time
  r.socket.send("MONITOR\c\L")
  raiseNoOK(r.readStatus(), r.pipeline.enabled)
"""

proc save*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Synchronously save the dataset to disk
  await r.sendCommand("SAVE")
  raiseNoOK(r, await r.readStatus())

proc shutdown*(r: Redis | AsyncRedis): Future[void] {.multisync.} =
  ## Synchronously save the dataset to disk and then shut down the server
  await r.sendCommand("SHUTDOWN")

  when r is Redis:
    let s = r.recvLineRaw()
    if len(s) != 0:
      raiseRedisError(r, s)
  else:
    let s = await managedRecvLine(r)
    if len(s) != 0:
      raiseRedisError(r, s)
    finaliseCommand(r)

proc slaveof*(r: Redis | AsyncRedis, host: string, port: string): Future[void] {.multisync.} =
  ## Make the server a slave of another instance, or promote it as master
  await r.sendCommand("SLAVEOF", host, @[port])
  raiseNoOK(r, await r.readStatus())

iterator hPairs*(r: Redis, key: string): tuple[key, value: string] =
  ## Iterator for keys and values in a hash.
  var
    contents = r.hGetAll(key)
    k = ""
  for i in items(contents):
    if k == "":
      k = i
    else:
      yield (k, i)
      k = ""

proc hPairs*(r: AsyncRedis, key: string): Future[seq[tuple[key, value: string]]] {.async.} =
  var
    contents = await r.hGetAll(key)
    k = ""

  result = @[]
  for i in items(contents):
    if k == "":
      k = i
    else:
      result.add((k, i))
      k = ""

type
  SendMode = enum
    normal, pipelined, multiple

proc someTests(r: Redis | AsyncRedis, how: SendMode): Future[seq[string]] {.multisync.} =
  var list: seq[string] = @[]

  if how == pipelined:
    r.startPipelining()
  elif how == multiple:
    await r.multi()

  await r.setk("nim:test", "Testing something.")
  await r.setk("nim:utf8", "こんにちは")
  await r.setk("nim:esc", "\\ths ągt\\")
  await r.setk("nim:int", "1")
  list.add(await r.get("nim:esc"))
  list.add($(await r.incr("nim:int")))
  list.add(await r.get("nim:int"))
  list.add(await r.get("nim:utf8"))
  list.add($(await r.hSet("test1", "name", "A Test")))
  var res = await r.hGetAll("test1")
  for r in res:
    list.add(r)
  list.add(await r.get("invalid_key"))
  list.add($(await r.lPush("mylist","itema")))
  list.add($(await r.lPush("mylist","itemb")))
  await r.lTrim("mylist",0,1)
  var p = await r.lRange("mylist", 0, -1)

  for i in items(p):
    if i.len > 0:
      list.add(i)

  list.add(await r.debugObject("mylist"))

  await r.configSet("timeout", "299")
  var g = await r.configGet("timeout")
  for i in items(g):
    list.add(i)

  list.add(await r.echoServ("BLAH"))

  case how
  of normal:
    return list
  of pipelined:
    return await r.flushPipeline()
  of multiple:
    return await r.exec()

proc assertListsIdentical(listA, listB: seq[string]) =
  assert(listA.len == listB.len)
  var i = 0
  for item in listA:
    assert(item == listB[i])
    i = i + 1

when defined(testing) and not defined(testasync) and isMainModule:
  echo "Testing sync valkey client"

  let r = connectValkey()

  # Test with no pipelining
  var listNormal = r.someTests(normal)

  # Test with pipelining enabled
  var listPipelined = r.someTests(pipelined)
  assertListsIdentical(listNormal, listPipelined)

  # Test with multi/exec() (automatic pipelining)
  var listMulti = r.someTests(multiple)
  assertListsIdentical(listNormal, listMulti)

  echo "Normal: ", listNormal
  echo "Pipelined: ", listPipelined
  echo "Multi: ", listMulti
elif defined(testing) and defined(testasync) and isMainModule:
  proc mainAsync(): Future[void] {.async.} =
    echo "Testing async valkey client"

    let r = await connectValkeyAsync()

    ## Set the key `nim_valkey:test` to the value `Hello, World`
    await r.setk("nim_valkey:test", "Hello, World")

    ## Get the value of the key `nim_valkey:test`
    let value = await r.get("nim_valkey:test")

    assert(value == "Hello, World")

    # Test with no pipelining
    var listNormal = await r.someTests(normal)

    # Test with pipelining enabled
    var listPipelined = await r.someTests(pipelined)
    assertListsIdentical(listNormal, listPipelined)

    # Test with multi/exec() (automatic pipelining)
    var listMulti = await r.someTests(multiple)
    assertListsIdentical(listNormal, listMulti)

    echo "Normal: ", listNormal
    echo "Pipelined: ", listPipelined
    echo "Multi: ", listMulti

  waitFor mainAsync()
