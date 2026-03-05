defmodule ExampleAppWeb.TodoController do
  use ExampleAppWeb, :controller

  alias ExampleApp.Todos

  def index(conn, _params) do
    todos = Todos.list_todos()
    render(conn, :index, todos: todos)
  end

  def create(conn, %{"todo" => todo_params}) do
    case Todos.create_todo(todo_params) do
      {:ok, _todo} ->
        conn |> put_flash(:info, "Todo created.") |> redirect(to: ~p"/todos")
      {:error, changeset} ->
        todos = Todos.list_todos()
        render(conn, :index, todos: todos, changeset: changeset)
    end
  end

  def toggle(conn, %{"id" => id}) do
    Todos.toggle_todo(id)
    redirect(conn, to: ~p"/todos")
  end

  def delete(conn, %{"id" => id}) do
    Todos.delete_todo(id)
    conn |> put_flash(:info, "Todo deleted.") |> redirect(to: ~p"/todos")
  end

  def crash(conn, %{"type" => "argument"}) do
    Todos.get_todo_or_fail!(-1)
    text(conn, "should not reach")
  end

  def crash(conn, %{"type" => "arithmetic"}) do
    _ = 1 / 0
    text(conn, "should not reach")
  end

  def crash(_conn, %{"type" => "timeout"}) do
    Process.sleep(100_000)
  end

  def crash(_conn, _params) do
    raise "deliberate Sentinel test crash"
  end

  def sentinel_status(conn, _params) do
    status = Sentinel.status()
    buckets = Sentinel.error_buckets()

    json(conn, %{
      status: status,
      error_buckets: Enum.map(buckets, fn b ->
        %{
          id: b.id,
          exception_type: b.signature.exception_type,
          message: b.signature.message_pattern,
          count: b.count,
          state: b.state
        }
      end)
    })
  end
end
