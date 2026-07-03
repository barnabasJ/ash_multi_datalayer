# Used by "mix format"
[
  import_deps: [:ash, :spark, :ecto, :ecto_sql],
  plugins: [Spark.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
