import valkey, unittest, asyncdispatch, os, strutils, options

proc getValkeyPassword(): string =
  let path = getHomeDir() / "valkey.creds"
  if fileExists(path):
    return readFile(path).strip()
  return ""

proc connectTest*(T: typedesc[Valkey]): Valkey =
  let pw = getValkeyPassword()
  if pw.len > 0:
    result = connectValkey(host = "localhost", password = pw)
  else:
    result = connectValkey(host = "localhost")

proc connectTest*(T: typedesc[AsyncValkey]): Future[AsyncValkey] {.async.} =
  let pw = getValkeyPassword()
  if pw.len > 0:
    result = await connectValkeyAsync(host = "localhost", password = pw)
  else:
    result = await connectValkeyAsync(host = "localhost")

template syncTests() =
  let r = connectTest(Valkey)
  let keys = r.keys("*")
  doAssert keys.len == 0, "Don't want to mess up an existing DB."

  test "simple set and get":
    const expected = "Hello, World!"

    r.setk("redisTests:simpleSetAndGet", expected)
    let actual = r.get("redisTests:simpleSetAndGet")

    check actual == expected

  test "increment key by one":
    const expected = 3

    r.setk("redisTests:incrementKeyByOne", "2")
    let actual = r.incr("redisTests:incrementKeyByOne")

    check actual == expected

  test "increment key by five":
    const expected = 10

    r.setk("redisTests:incrementKeyByFive", "5")
    let actual = r.incrBy("redisTests:incrementKeyByFive", 5)

    check actual == expected

  test "decrement key by one":
    const expected = 2

    r.setk("redisTest:decrementKeyByOne", "3")
    let actual = r.decr("redisTest:decrementKeyByOne")

    check actual == expected

  test "decrement key by three":
    const expected = 7

    r.setk("redisTest:decrementKeyByThree", "10")
    let actual = r.decrBy("redisTest:decrementKeyByThree", 3)

    check actual == expected

  test "append string to key":
    const expected = "hello world"

    r.setk("redisTest:appendStringToKey", "hello")
    let keyLength = r.append("redisTest:appendStringToKey", " world")

    check keyLength == len(expected)
    check r.get("redisTest:appendStringToKey") == expected

  test "check key exists":
    r.setk("redisTest:checkKeyExists", "foo")
    check r.exists("redisTest:checkKeyExists") == true

  test "delete key":
    r.setk("redisTest:deleteKey", "bar")
    check r.exists("redisTest:deleteKey") == true

    check r.del(@["redisTest:deleteKey"]) == 1
    check r.exists("redisTest:deleteKey") == false

  test "rename key":
    const expected = "42"

    r.setk("redisTest:renameKey", expected)
    discard r.rename("redisTest:renameKey", "redisTest:meaningOfLife")

    check r.exists("redisTest:renameKey") == false
    check r.get("redisTest:meaningOfLife") == expected

  test "get key length":
    const expected = 5

    r.setk("redisTest:getKeyLength", "hello")
    let actual = r.strlen("redisTest:getKeyLength")

    check actual == expected

  test "push entries to list":
    for i in 1..5:
      check r.lPush("redisTest:pushEntriesToList", $i) == i

    check r.llen("redisTest:pushEntriesToList") == 5

  test "pfcount supports single key and multiple keys":
    discard r.pfadd("redisTest:pfcount1", @["foo"])
    check r.pfcount("redisTest:pfcount1") == 1

    discard r.pfadd("redisTest:pfcount2", @["bar"])
    check r.pfcount(@["redisTest:pfcount1", "redisTest:pfcount2"]) == 2

  test "engine detection (sync)":
    let valkeyFlag = r.isValkey()
    let redisFlag = r.isRedis()

    # they shouldn't both be true
    check not (valkeyFlag and redisFlag)

    check valkeyFlag or redisFlag

  test "pipeline flush works":
    r.startPipelining()
    r.setk("pipelineTest:key1", "value1")
    discard r.get("pipelineTest:key1")
    let replies = r.flushPipeline()
    check replies.contains("value1")

  # TODO: Ideally tests for all other procedures, will add these in the future

  # delete all keys in the DB at the end of the tests
  discard r.flushdb()
  r.quit()
suite "valkey tests":
  syncTests()

suite "valkey async tests":
  let r = waitFor connectTest(AsyncValkey)
  let keys = waitFor r.keys("*")
  doAssert keys.len == 0, "Don't want to mess up an existing DB."

  test "issue #6":
    # See `tawaitorder` for a test that doesn't depend on Redis.
    const count = 5
    proc retr(key: string, expect: string) {.async.} =
      let val = await r.get(key)

      doAssert val == expect

    proc main(): Future[bool] {.async.} =
      for i in 0 ..< count:
        await r.setk("key" & $i, "value" & $i)

      var futures: seq[Future[void]] = @[]
      for i in 0 ..< count:
        futures.add retr("key" & $i, "value" & $i)

      for fut in futures:
        await fut

      return true

    check (waitFor main())

  test "subscribe then quit doesn't hang (issue #34)":
    proc main(): Future[bool] {.async.} =
      let sub = await connectTest(AsyncValkey)
      await sub.subscribe("channel_deadlock_test")
      let ok = await withTimeout(sub.quit(), 2000)
      return ok

    check waitFor main()

  test "pub/sub":

    proc main() {.async.} =
      let sub = await connectTest(AsyncValkey)
      let pub = await connectTest(AsyncValkey)

      let listerns = await pub.publish("channel1", "hi there")
      doAssert listerns == 0

      await sub.subscribe("channel1")
      # you should only call sub.nextMessage() from now on

      discard await pub.publish("channel1", "one")
      discard await pub.publish("channel1", "two")
      discard await pub.publish("channel1", "three")

      doAssert (await sub.nextMessage()).message == "one"
      doAssert (await sub.nextMessage()).message == "two"
      doAssert (await sub.nextMessage()).message == "three"

    waitFor main()

  test "message":
    let event_option = parseEvent(["message", "chan", "hi"])
    check event_option.isSome
    let event = event_option.get()
    check event.kind == pekMessage
    check event.channel == "chan"
    check event.data == "hi"

  test "pmessage":
    let event_option = parseEvent(["pmessage", "pat*", "chan", "hello"])
    check event_option.isSome
    let event = event_option.get()
    check event.kind == pekPMessage
    check event.pattern == "pat*"
    check event.channel == "chan"
    check event.data == "hello"

  test "subscribe data = str(count)":
    let event_option = parseEvent(["subscribe", "chan", "1"])
    check event_option.isSome
    let event = event_option.get()
    check event.kind == pekSubscribe
    check event.channel == "chan"
    check event.data == "1"

  test "bad arity -> none":
    check parseEvent(["message", "chan"]).isNone

  test "lazy pubsub":
    let r = waitFor connectTest(AsyncValkey)
    let ps = r.pubsub(ignoreSubscribeMessages = true)
    check ps.conn.isNil
    check ps.ignoreSubscribeMessages == true
    check ps.params.host == "localhost"
    check int(ps.params.port) == 6379

  test "check subscribe acks with pubsub lazy connection":
    proc main(): Future[bool] {.async.} =
      let base = await connectTest(AsyncValkey)
      let ps = base.pubsub(ignoreSubscribeMessages = false)
      doAssert ps.conn.isNil

      let ch = "test_pubsub_sub_ack"
      await ps.subscribe(ch)
      doAssert ps.conn.isNil == false

      let fut = ps.parseResponse()
      let frame = await fut

      doAssert frame.len == 3
      doAssert frame[0] == "subscribe"
      doAssert frame[1] == ch
      doAssert frame[2] == "1"

      await ps.close()
      await base.close()
      return true
    check waitFor main()


  test "pubsub ignoreSubscribeMessages":
    proc main(): Future[bool] {.async.} =
      let base = await connectTest(AsyncValkey)
      let pub = await connectTest(AsyncValkey)
      let ps = base.pubsub(ignoreSubscribeMessages = true)

      let ch1 = "test_pubsub_ignore_1"
      let ch2 = "test_pubsub_ignore_2"

      # subscribe to ch1 and don't consume its ack
      await ps.subscribe(ch1)

      # subscribe to ch2 and don't consume its ack
      await ps.subscribe(ch2)

      # publish to ch1
      discard await pub.publish(ch1, "hello")

      # should get the message from ch1 not the acks from ch1 or ch2
      let fut = ps.receiveEvent()
      doAssert await withTimeout(fut, 2000)
      let event = await fut

      doAssert event.kind == pekMessage
      doAssert event.channel == ch1
      doAssert event.data == "hello"

      await ps.close()
      await pub.close()
      await base.close()
      return true

    check waitFor main()

  test "pubsub receiveMessage":
    proc main(): Future[bool] {.async.} =
      let base = await connectTest(AsyncValkey)
      let pub  = await connectTest(AsyncValkey)
      let ps   = base.pubsub(ignoreSubscribeMessages = false)

      let ch1 = "test_pubsub_receive_1"
      let ch2 = "test_pubsub_receive_2"

      try:
        await ps.subscribe(ch1)
        discard await ps.receiveEvent()  # consume subscribe ack for ch1

        await ps.subscribe(ch2)          # leave ch2 ack pending
        let msgFut = ps.receiveMessage() # should skip ch2 ack internally

        discard await pub.publish(ch1, "payload")

        doAssert await withTimeout(msgFut, 2000)
        let event = await msgFut

        doAssert event.kind == pekMessage
        doAssert event.channel == ch1
        doAssert event.data == "payload"
        return true
      finally:
        discard await withTimeout(ps.close(), 500)
        discard await withTimeout(pub.close(), 500)
        discard await withTimeout(base.close(), 500)

    check waitFor main()

  test "engine detection (async)":
    let valkeyFlag = waitFor r.isValkey()
    let redisFlag = waitFor r.isRedis()

    # they shouldn't both be true
    check not (valkeyFlag and redisFlag)

    check valkeyFlag or redisFlag

  discard waitFor r.flushdb()
  waitFor r.quit()


when compileOption("threads"):
  proc threadFunc() {.thread.} =
    suite "valkey threaded tests":
      syncTests()

  var th: Thread[void]
  createThread(th, threadFunc)
  joinThread(th)

