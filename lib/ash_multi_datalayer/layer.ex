defmodule AshMultiDatalayer.Layer do
  @moduledoc """
  A named underlying data layer declared in a `multi_data_layer` section.
  """

  defstruct [:name, :module, __spark_metadata__: nil]

  @type t :: %__MODULE__{name: atom(), module: module()}
end
