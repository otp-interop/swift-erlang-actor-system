# Swift Erlang Actor System
This library provides a runtime for Swift Distributed Actors backed by [`erl_interface`](https://www.erlang.org/doc/apps/erl_interface/ei_users_guide.html) from Erlang/OTP.

## Getting Started
Create an instance of the ``ErlangActorSystem`` with a `name` and `cookie` used to verify the connection.

```swift
let actorSystem = try ErlangActorSystem(name: "node1", cookie: "cookie")
```

You can connect multiple actor systems (nodes) together with
``ErlangActorSystem/connect(to:)``.

```swift
try await actorSystem.connect(to: "node2@localhost")
```

> You can connect to any node visible to [EPMD](https://www.erlang.org/doc/apps/erts/epmd_cmd) (Erlang Port Mapper Daemon) by its node name and hostname.
> You can also connect directly by IP address and port if you're not using EPMD.

Create distributed actors that use the ``ErlangActorSystem``.

```swift
distributed actor Counter {
    typealias ActorSystem = ErlangActorSystem

    private(set) var count: Int = 0

    distributed func increment() {
        count += 1
    }

    distributed func decrement() {
        count -= 1
    }
}
```

Create an instance of a distributed actor by passing your ``ErlangActorSystem`` instance.

```swift
let counter = Counter(actorSystem: actorSystem)
try await counter.increment()
#expect(await counter.count == 1)
```

Resolve remote actors by their ID. The ID can be a [PID](https://www.erlang.org/doc/system/data_types#pid) or a registered name.
An actor can register a name on a remote node with ``ErlangActorSystem/register(_:name:)``.

```swift
let remoteCounter = try Counter.resolve(id: .name("counter", node: "node2@localhost"))
try await remoteCounter.increment()
```

Codable values are encoded to Erlang's [External Term Format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html).
Calls are sent to remote actors using the [`GenServer` message format](https://hexdocs.pm/elixir/1.18.3/GenServer.html).

## Connecting to Elixir
You can use this actor system purely from Swift. However, since it uses Erlang's C node API, it can interface directly with Erlang/Elixir nodes.

To test this, you can start IEx (Interactive Elixir) as a distributed node:

```sh
iex --sname iex
```

Get the cookie from IEx:

```ex
iex(iex@hostname)1> Node.get_cookie()
```

From Swift, create an ``ErlangActorSystem`` with the same cookie value (without the leading colon `:`)
and connect it to the IEx node.

```swift
let actorSystem = try ErlangActorSystem(name: "swift", cookie: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
try await actorSystem.connect(to: "iex@hostname")
```

You can confirm that the Swift node has connected to IEx with `Node.list/1`:

```ex
iex(iex@hostname)2> Node.list(:hidden)
[:"swift@hostname"]
```

Now create an distributed actor and register a name for it.

```swift
@StableNames
distributed actor PingPong {
    typealias ActorSystem = ErlangActorSystem
    
    @StableName("ping")
    distributed func ping() -> String {
        return "pong"
    }
}

let pingPong = PingPong(actorSystem: actorSystem)
try await actorSystem.register(pingPong, name: "ping_pong")
```

In IEx, use [`GenServer.call/3`](https://hexdocs.pm/elixir/1.18.3/GenServer.html#call/3) from Elixir to make distributed calls on your Swift actor.

```ex
iex(iex@hostname)3> GenServer.call({:ping_pong, :"swift@hostname"}, :ping)
"pong"
```

## Stable Names
By default, Swift uses mangled function names to identify remote calls.
To interface with other languages, we need to establish stable names for distributed functions.

The ``StableName`` macro lets you declare a custom name for a distributed function.
Add the ``StableName`` macro to each `distributed func`/`distributed var` and the `@StableNames` macro to the actor.

This will generate a mapping between your stable names and the mangled function names used by the Swift runtime.

```swift
@StableNames // <- generates the mapping between stable and mangled names
distributed actor Counter {
    typealias ActorSystem = ErlangActorSystem

    private var _count = 0

    @StableName("count") // <- declares the name to use for this member
    distributed var count: Int { _count }

    @StableName("increment") // <- can be used on `var` or `func`
    distributed func increment() {
        _count += 1
    }

    @StableName("decrement") // <- all stable names must be unique
    distributed func decrement() {
        _count -= 1
    }
}
```

## External Actors
You may have some GenServers that are only declared in Erlang/Elixir:

```elixir
defmodule Counter do
    use GenServer

    @impl true
    def init(count), do: {:ok, count}

    @impl true
    def handle_call(:count, _from, state) do
        {:reply, state, state}
    end

    @impl true
    def handle_call(:increment, _from, state) do
        {:reply, :ok, state + 1}
    end

    @impl true
    def handle_call(:decrement, _from, state) do
        {:reply, :ok, state - 1}
    end
end
```

To interface with these GenServers, create a protocol in Swift.
Add the `Resolvable` and `StableName` macros. You must declare a conformance to `HasStableNames` manually.

```swift
@Resolvable
@StableNames
protocol Counter: DistributedActor, HasStableNames where ActorSystem == ErlangActorSystem {
    @StableName("count")
    distributed var count: Int { get }

    @StableName("increment")
    distributed func increment()

    @StableName("decrement")
    distributed func decrement()
}
```

A concrete actor implementing this protocol called `$Counter` will be created.
Use this implementation to resolve the remote actor.

```swift
let counter: some Counter = try $Counter.resolve(
    id: .name("counter", node: "iex@hostname"),
    using: actorSystem
)

try await counter.increment()
#expect(try await counter.count == 1)
```
