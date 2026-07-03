# Boot the backend's RPC router in-process (same BEAM) so the end-to-end test
# drives the LiveView against a real HTTP server without a detached process.
# The router is wrapped in a counting plug: the multi-datalayer proof tests
# assert exact server request counts ("the second read made zero RPCs").
{:ok, _} = Application.ensure_all_started(:bandit)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:ash)

TodoClient.Test.CountingRouter.install_counter!()

port = 4997
{:ok, _} = Bandit.start_link(plug: TodoClient.Test.CountingRouter, port: port, startup_log: false)
Application.put_env(:ash_remote, :base_url, "http://127.0.0.1:#{port}")

ExUnit.start()
