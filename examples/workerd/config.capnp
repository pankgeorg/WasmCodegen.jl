# workerd's configuration: workerd serve config.capnp (check.mjs runs it)
using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [(name = "wasmcodegen", worker = .worker)],
  sockets = [(name = "http", address = "127.0.0.1:8790", http = (), service = "wasmcodegen")],
);

const worker :Workerd.Worker = (
  # (`nodejs_compat`, for julia_io.mjs's `node:` imports, is on by default from 2026-08-04)
  compatibilityDate = "2026-10-31",
  modules = [
    (name = "worker.mjs", esModule = embed "worker.mjs"),
    (name = "julia.mjs", esModule = embed "../../js/julia.mjs"),
    (name = "julia_io.mjs", esModule = embed "../../js/julia_io.mjs"),
    (name = "julia_task.mjs", esModule = embed "../../js/julia_task.mjs"),
    (name = "lorenz.wasm", wasm = embed "../lorenz/lorenz.wasm"),
    (name = "tasks.wasm", wasm = embed "tasks.wasm"),
    (name = "env.wasm", wasm = embed "env.wasm"),
  ],
);
