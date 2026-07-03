# ash_multi_datalayer example — a client-side ETS cache over ash_remote

ash_remote's todo example, with one twist: the client's generated resources
run `AshMultiDatalayer.DataLayer` — an ETS cache layered over
`AshRemote.DataLayer`. Filtered reads that hit the coverage ledger are served
locally with **zero HTTP requests**; misses fall through to the server and
warm the cache; writes go server-first and the returned record is propagated
into the cache.

```
example/
  todo_server/   Ash backend (pure ash_remote — proof the layering is
                 invisible to the server). Serves /rpc/run + /manifest.json
                 on port 4020.
  todo_client/   A LiveView app on port 4002. Generated resources declare:

                   multi_data_layer do
                     layer :cache, Ash.DataLayer.Ets
                     layer :remote, AshRemote.DataLayer
                     read_order [:cache, :remote]
                     write_order [:remote, :cache]
                   end
```

## The flow

```
todo_server ──/manifest.json──►  mix ash_remote.gen  ──►  TodoClient.Remote.{TodoList,Todo,User,Priority}
     ▲                                                              │
     │                                    ┌── hit ──── ETS cache ◄──┤ AshMultiDatalayer.DataLayer
     └──────── /rpc/run ◄──── miss / write┘                         │
                                                          TodoClient.Live (AshPhoenix.Form)
```

## The 60-second demo

1. `./run.sh`, then open <http://localhost:4002>.
2. Add a couple of todos, then use the **Browse** panel: flip between the
   All / active / done tabs and the priority filter. The first click of each
   combination is a miss (one RPC, watch the `debug_requests` log in the
   terminal); every repeat — and every *narrower* filter of something already
   loaded — is a wire-silent hit. The footer counts hits/misses/backfills/
   invalidations live from the library's telemetry.
3. Add or toggle a todo: the footer shows an invalidation (row-aware — only
   coverage matching the changed row is dropped), the next browse read is one
   RPC, and it's cached again after that.
4. Click **cache ON** to flip the kill-switch: every browse click now logs an
   RPC until you switch it back.

The top list view (aggregates + the `overdue?` calculation) intentionally
RPCs on every load — computed values are never served from the cache, so the
counts are always the server's truth.

The automated proof lives in
`todo_client/test/todo_client/multi_datalayer_test.exs`: an RPC-counting
router asserts wire silence exactly (the inverse of ash_remote's "the server
WAS called" tests), covering identical-read hits, filter subsumption
(eq/range/enum-set), write-through with server-computed defaults, row-aware
invalidation, calc/aggregate fall-through, divergence detection of
out-of-band server writes, and the kill-switch.

## What the domain showcases

One `Ash.Query.load` in the LiveView exercises the full loading surface:

```elixir
TodoList
|> Ash.Query.load([:todo_count, :completed_count, :user,
                   todos: [:overdue?, subtasks: [:overdue?]]])
|> Ash.read!()
```

- **Relationships** — `TodoList belongs_to :user` / `has_many :todos`, and the
  self-referential `Todo has_many :subtasks` (FK `parent_id`). Loaded via Ash's
  batched follow-up reads, each itself an RPC call.
- **Aggregates** — `todo_count` and `completed_count` (a filtered count) are
  computed by the server's data layer; the client mirrors them as loadable
  stubs and just asks for them by name.
- **Calculations** — `Todo.overdue?` is a real expression on the server; the
  client stub only knows its name and type, the server supplies the value.
- **Enum type** — `Priority` round-trips through codegen as a named type.
- **Validations** — `Todo`'s `string_length(:title, min: 3)` is mirrored onto
  the generated client resource: the form rejects short titles instantly,
  client-side, with no RPC; the server still enforces it on every write.

## Exposing actions (server)

The backend declares what's exposed, ash_typescript-style:

```elixir
# todo_server/lib/todo_server/domain.ex
use Ash.Domain, extensions: [AshRemote.Rpc]

rpc do
  resource TodoServer.Todo do
    expose :read
    expose :create
    expose :update
    expose :destroy
  end

  resource TodoServer.TodoList do
    expose :read
    expose :create
  end

  resource TodoServer.User do
    expose :read
    expose :create
  end
end
```

and mounts the built-in router (no custom RPC code):

```elixir
# todo_server/lib/todo_server/rpc_router.ex
use AshRemote.Server.Router, otp_app: :todo_server
```

## Look at it (browser)

Two shells:

```sh
# 1) the backend (http://localhost:4020, manifest at /manifest.json)
cd example/todo_server && mix run --no-halt   # port 4020

# 2) the LiveView client — then open http://localhost:4002
cd example/todo_client && mix run --no-halt   # port 4002
```

## Automated end-to-end test (no browser needed)

`todo_client`'s test boots the backend's RPC router in-process and drives the
LiveView (mount → create → toggle → delete), asserting each change round-tripped
to the server:

```sh
cd example/todo_client && mix test
```

## Regenerate the client resources

Both steps are wired as mix aliases (see each `mix.exs`):

```sh
cd todo_server && mix manifest.publish   # writes ../todo_client/priv/manifest.json
cd ../todo_client && mix remote.gen      # ash_remote.gen → lib/todo_client/remote/*
```

Regeneration is non-destructive: existing modules only gain what the manifest
added; your own edits and additions are kept. Anything that drifts from the
manifest (an entity you changed, or one the server removed) is reported as a
warning — add `--interactive` to `mix ash_remote.gen` to resolve each one
interactively instead.

> `ash` comes from Hex (`~> 3.29`, for `Ash.Info.Manifest`); `ash_remote` is a
> relative path dep (`../../../ash_remote`); `ash_multi_datalayer` is the repo root (`../..`).
