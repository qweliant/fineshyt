defmodule Orchestrator.Embedding do
  @moduledoc """
  Ecto type storing a CLIP image embedding as a packed float32 binary blob.

  The vector is never searched inside the database — it's always loaded into
  Elixir and shipped to the Python ai_worker, which does all the math (cosine
  clustering for bursts, Ridge regression for preference). So a plain blob is
  sufficient and keeps SQLite free of any loadable vector extension.

  Wire format: each element is a little-endian IEEE-754 32-bit float, packed
  back-to-back. A 768-dim embedding is therefore 768 * 4 = 3072 bytes. The
  endianness is pinned here so the one-time Postgres→SQLite migration and the
  runtime read/write path always agree.

    * `cast/1`  — accepts a list of numbers (the shape the ai_worker returns)
    * `dump/1`  — list → binary blob for storage
    * `load/1`  — binary blob → list of floats
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_), do: :error

  @impl true
  def dump(value) when is_list(value) do
    {:ok, for(n <- value, into: <<>>, do: <<n::float-32-little>>)}
  end

  def dump(_), do: :error

  @impl true
  def load(blob) when is_binary(blob) do
    {:ok, for(<<n::float-32-little <- blob>>, do: n)}
  end

  def load(_), do: :error
end
