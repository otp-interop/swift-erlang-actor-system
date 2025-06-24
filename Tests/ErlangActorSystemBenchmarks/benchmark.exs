n = 100_000

defmodule PingPong do
  use GenServer

  def init(state), do: {:ok, state}

  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

{:ok, _pid} = Node.start(:"a@127.0.0.1")

{create_time, actors} = :timer.tc(fn ->
    for _i <- 1..n do
      {:ok, pid} = GenServer.start_link(PingPong, %{})
      pid
    end
end)
IO.puts "create #{n} actors took #{create_time / 1_000_000} seconds"

# start a peer node that remotely calls our PingPong gen servers, then returns
# the total timing.
Process.register(self(), :origin)
_port = Port.open(
    {:spawn_executable, System.find_executable("elixir")},
    [:binary, :nouse_stdio, :hide, args: ["Tests/ErlangActorSystemBenchmarks/node_b.exs"]]
)
receive do
    pid ->
        send(pid, actors)
end
receive do
    ping_time ->
        IO.puts "ping #{n} actors took #{ping_time / 1_000_000} seconds"
end
