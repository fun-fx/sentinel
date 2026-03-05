defmodule ExampleApp.Todos do
  import Ecto.Query
  alias ExampleApp.{Repo, Todos.Todo}

  def list_todos do
    Todo |> order_by(desc: :inserted_at) |> Repo.all()
  end

  def get_todo!(id), do: Repo.get!(Todo, id)

  def create_todo(attrs) do
    %Todo{} |> Todo.changeset(attrs) |> Repo.insert()
  end

  def toggle_todo(id) do
    todo = get_todo!(id)
    todo |> Todo.changeset(%{completed: !todo.completed}) |> Repo.update()
  end

  def delete_todo(id) do
    todo = get_todo!(id)
    Repo.delete(todo)
  end

  def get_todo_or_fail!(id) do
    case Integer.parse(to_string(id)) do
      {n, _} when n < 0 -> raise ArgumentError, "negative IDs are not supported"
      _ -> :ok
    end
    get_todo!(id)
  end
end
