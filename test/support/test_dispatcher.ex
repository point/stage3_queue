defmodule Stage3Queue.TestDispatcher do
  @dialyzer {:nowarn_function, dispatch: 1}
  @dialyzer {:nowarn_function, dispatch: 2}

  def dispatch("sleep", time) do
    Process.sleep(time)
  end

  def dispatch("sleep&send", time, pid, message) do
    Process.sleep(time)
    send(pid, message)
  end

  def dispatch("die") do
    f = fn -> "a" end
    :ok = f.()
  end

  def dispatch("sleep&die") do
    Process.sleep(50)
    f = fn -> "a" end
    :ok = f.()
  end

  def dispatch("fib") do
    do_fib(123_456_789)
  end

  def do_fib(0) do
    0
  end

  def do_fib(1) do
    1
  end

  def do_fib(n) do
    do_fib(n - 1) + do_fib(n - 2)
  end
end
