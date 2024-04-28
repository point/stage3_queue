defmodule Stage3QueueWeb.QueueControllerTest do
  use Stage3QueueWeb.ConnCase

  test "Queue correctly", %{conn: conn} do
    conn = post(conn, ~p"/", %{"topic" => "default", "function" => "sleep", "args" => [50]})
    assert body = json_response(conn, 200)
    assert %{"id" => id, "status" => "ok"} = body

    conn = get(conn, ~p"/#{id}")
    assert body = json_response(conn, 200)
    assert %{"status" => "running"} = body

    conn = post(conn, ~p"/", %{"topic" => "default", "function" => "sleep", "args" => [50]})
    assert body = json_response(conn, 200)
    assert %{"id" => id2, "status" => "ok"} = body

    refute id == id2

    conn = get(conn, ~p"/#{id2}")
    assert body = json_response(conn, 200)
    assert %{"status" => "queued"} = body

    Process.sleep(100)
  end

  test "Aborts correctly", %{conn: conn} do
    conn = post(conn, ~p"/", %{"topic" => "default", "function" => "sleep", "args" => [50]})
    assert %{"id" => _id1, "status" => "ok"} = json_response(conn, 200)

    conn = post(conn, ~p"/", %{"topic" => "default", "function" => "sleep", "args" => [50]})
    assert %{"id" => id2, "status" => "ok"} = json_response(conn, 200)

    conn = delete(conn, ~p"/#{id2}")
    assert %{"message" => "Task aborted", "status" => "ok"} = json_response(conn, 200)

    Process.sleep(100)
  end

  test "Error, in case of incorrect params", %{conn: conn} do
    assert_error_sent 400, fn ->
      _conn = post(conn, ~p"/", %{"function" => "sleep", "args" => [50]})
    end

    conn = post(conn, ~p"/", %{"topic" => "unexistent", "function" => "sleep", "args" => [50]})
    assert %{"message" => "Topic is not found", "status" => "error"} = json_response(conn, 400)

    Process.sleep(100)
  end
end
