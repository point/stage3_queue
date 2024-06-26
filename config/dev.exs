import Config

# Configure your database
config :stage3_queue, Stage3Queue.Repo,
  database: Path.expand("../stage3_queue_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :stage3_queue, Stage3QueueWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: "qtiyEYoWfr+UAH/vn1lUdwmMjbc/L9W3elr0Po/w2JJTPlUCESSDyVa/0iXKTqKr",
  watchers: []

# ## SSL Support
#
# In order to use HTTPS in development, a self-signed
# certificate can be generated by running the following
# Mix task:
#
#     mix phx.gen.cert
#
# Run `mix help phx.gen.cert` for more information.
#
# The `http:` config above can be replaced with:
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       keyfile: "priv/cert/selfsigned_key.pem",
#       certfile: "priv/cert/selfsigned.pem"
#     ],
#
# If desired, both `http:` and `https:` keys can be
# configured to run both http and https servers on
# different ports.

# Watch static and templates for browser reloading.
# config :stage3_queue, Stage3QueueWeb.Endpoint,
#   live_reload: [
#     patterns: [
#       ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
#       ~r"lib/stage3_queue_web/(controllers|live|components)/.*(ex|heex)$"
#     ]
#   ]

# Enable dev routes for dashboard and mailbox
config :stage3_queue, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

# Include HEEx debug annotations as HTML comments in rendered markup
# config :phoenix_live_view, :debug_heex_annotations, true
