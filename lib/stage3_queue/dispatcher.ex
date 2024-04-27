defmodule Stage3Queue.Dispatcher do
  @dialyzer {:nowarn_function, dispatch: 1}
  @dialyzer {:nowarn_function, dispatch: 2}

  def dispatch("sleep", time) do
    Process.sleep(time)
  end

  def dispatch("sleep&die") do
    Process.sleep(2_000)
    f = fn -> "a" end
    :ok = f.()
  end
end
