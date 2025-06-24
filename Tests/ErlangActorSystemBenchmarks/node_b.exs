Node.start(:"b@127.0.0.1")
Node.ping(:"a@127.0.0.1")

send({:origin, :"a@127.0.0.1"}, self())
receive do
  actors ->
    {time, _} = :timer.tc(fn ->
      Task.async_stream(actors, fn actor ->
        GenServer.call(actor, :ping)
      end)
      |> Enum.to_list()
    end)
    send({:origin, :"a@127.0.0.1"}, time)
end
