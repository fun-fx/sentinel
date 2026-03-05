defmodule ExampleApp.Repo.Migrations.CreateTodos do
  use Ecto.Migration

  def change do
    create table(:todos) do
      add :title, :string, null: false
      add :completed, :boolean, default: false
      timestamps()
    end
  end
end
