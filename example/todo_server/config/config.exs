import Config

config :ash, default_string_length_count: :codepoints

config :todo_server,
  ash_domains: [TodoServer.Domain],
  port: String.to_integer(System.get_env("PORT", "4020"))

config :ash, :validate_domain_config_inclusion?, false
