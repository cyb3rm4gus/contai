# Wiki REH Resolver

A ~60-line VSCodium **remote authority resolver** with **zero runtime dependencies**.

When you open `vscode-remote://wiki-reh+<name>/path`, it looks up `<name>` in the
`wikiReh.hosts` setting and tells the editor which `host:port` (+ connection
token) the container's REH server is on. That's the whole job — no SSH, no keys,
no spawning, no downloads. Built and installed locally (see `../build-resolver.sh`),
never fetched from a marketplace.

## Settings

```jsonc
"wikiReh.hosts": [
  {
    "name": "wiki-agent",
    "host": "localhost",
    "port": 8000,
    "connectionToken": "<from the container>",
    "folders": [ { "name": "agent", "path": "/home/agent" } ]
  }
]
```

Requires the proposed `resolvers` API — the extension id must be listed in
`argv.json` under `enable-proposed-api` (the build script prints the exact line).
