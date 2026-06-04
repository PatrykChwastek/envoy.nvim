# envoy.nvim

A buffer-driven HTTP client for Neovim, focused on working with Elasticsearch from inside `.http` / `.rest` files.

```http
@baseUrl = http://localhost:9200

### Count members
POST {{baseUrl}}/items/_count
{
  "query": { "term": { "joinField": "membership" } }
}
```

Press `<CR>` on any line of the request — the response opens in a side
window. That's the whole loop.

## Features

- **Run requests** with `<CR>`, visual selection, `<C-CR>` to run + focus
  result, `<leader><CR>` to re-run last
- **Picker** with `<leader>R` — Telescope (if installed) or
  `vim.ui.select`. Telescope picker fuzzy-searches the `# comment` above
  each request and supports `<Tab>` multi-select
- **Elasticsearch-aware completion** via `omnifunc` (works with nvim-cmp
  `cmp-omni`, blink.cmp `omni`, or `<C-x><C-o>` directly):
  - Index names from `/_cat/indices` after `METHOD `
  - DSL keywords inside JSON bodies (`query`, `bool`, `aggs`, …)
  - Mapping fields from the target index, deduplicated across nested
    objects (typing `na` suggests `name`, not `chat.name` / `user.name`)
- **Bulk API** — multi-line JSON gets auto-compacted to NDJSON,
  `Content-Type` set, response shown per-item with ✓/✗ status
- **Kibana Dev Tools import** — paste from Kibana, then `:lua
  require'envoy'.import_kibana()` converts triple-quoted strings and
  inserts as `.http` syntax
- **Variables** — file-level `@var`, env file (`http-client.env.json`),
  built-ins (`{{baseUrl}}`, `{{es_url}}`)
- **Stable folding** for both `.http` and result buffers
- **Unicode whitespace sanitization** — invisible chars from pasted JSON
  (U+00A0, U+200B, U+FEFF, …) stripped before sending

## Install

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "PatrykChwastek/envoy.nvim",
    ft   = { "http", "rest" },
    cmd  = { "EnvoyRefresh", "EnvoyDebug" },
    opts = {
        elastic = { base_url = "http://localhost:9200" },
        env_name = "dev",
    },
}
```

Minimal manual setup:

```lua
require("envoy").setup({
    elastic = { base_url = "http://localhost:9200" },
})
```

### Completion engines

The `omnifunc` works with any completion engine. To wire it into nvim-cmp:

```lua
require("cmp").setup.filetype("http", {
    sources = {
        { name = "omni" },
        { name = "buffer" },
        { name = "path" },
    },
})
```

(Requires `hrsh7th/cmp-omni`.)

## Configuration

Full defaults:

```lua
require("envoy").setup({
    result_win_width   = 80,
    env_file           = nil,        -- auto: http-client.env.json next to buffer
    env_name           = "dev",
    fold_level_on_open = 0,          -- 0 = fold all, 99 = expand all
    picker             = "auto",     -- "auto" | "telescope" | "native"
    keys = {
        run            = "<CR>",
        run_focus      = "<C-CR>",
        run_last       = "<leader><CR>",
        pick           = "<leader>R",
        next_request   = "]r",
        prev_request   = "[r",
        format_body    = "<leader>fj",
        help           = "g?",
    },
    elastic = {
        base_url    = nil,
        api_key     = nil,           -- "ApiKey <value>" auto-injected
        format_hits = true,          -- flatten _search hits.hits in result
    },
    complete = {
        enabled        = true,
        fetch_indices  = true,
        fetch_mappings = true,
    },
})
```

Set any key to `""` to disable that mapping.

## File format

Both explicit (`###`) and implicit (Kibana-style) separators work:

```http
### Get one
GET {{baseUrl}}/items/123

### Search
POST {{baseUrl}}/items/_search
{ "query": { "match_all": {} } }
```

```http
GET /_cat/indices?v
GET items/_mapping

# comments before a method line attach to that request
POST items/_count
{ "query": { "match_all": {} } }
```

## Commands

| Command         | What it does                                                     |
| --------------- | ---------------------------------------------------------------- |
| `:EnvoyRefresh` | Clear + re-fetch the ES indices / mapping caches                 |
| `:EnvoyDebug`   | Show cache state, last error, parsed requests, cursor's pick     |

`:EnvoyDebug` is the first stop when something feels off — it prints every
parsed request with line ranges so you can see exactly which one `<CR>`
will run.
