defmodule AshMultiDatalayer.Layer do
  @moduledoc """
  A named underlying data layer declared in a `multi_data_layer` section.
  """

  defstruct [:name, :module]

  @type t :: %__MODULE__{name: atom(), module: module()}
end
