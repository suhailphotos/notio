# notio

**Neovim keymaps → Notion, on demand.**  
Collect your Neovim keymaps, fingerprint them, and **sync** (create/update) rows in a Notion database—with rich-text fields, relations, and guardrails to protect manual edits.

> Built for my setup first. It assumes a specific Notion schema (see below) with an **Application** relation and optional **Plugin** relations.

---

## What it does

- Scans **all modes** (`n, v, x, s, i, c, t, o`) for global + loaded buffer-local maps.
- Normalizes LHS tokens (e.g. `<Space> → <leader>`, `<c-x> → <C-X>`, common key name casing) for stability.
- Merges multi-mode bindings to one row (e.g., Visual+Normal → single page with **Mode** multiselect).
- Generates a **stable UID**: `"<M>|<lhs>|<Scope>"` (`M ∈ {n,V,i,c,t,o}`; Scope = Global/Buffer/Project).
- Guesses **Plugin** and **Category** by description/RHS/origin.
- **Skips built-ins** and noisy prefix families by default.
- **Syncs to Notion**: create/update/rebind with rich-text `Action`, `Description`, relations, selects, etc.
- Provides dry-run planning and a live log buffer during sync.

---

## Install

With **lazy.nvim** (GitHub):

```lua
{
  "suhailphotos/notio",
  name = "notio",
  version = "v0.1.1",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {
    database_id = "275a1865-b187-81b9-bc4a-fbe5d44e2911",
    app_page_id = "13fa1865-b187-815a-b3d7-f0a23559e641",
    plugin_pages = {
      ["yazi.nvim"]            = "278a1865-b187-8015-9e18-c51affadd8b1",
      ["telescope.nvim"]       = "278a1865-b187-80ac-9b86-c94087ad60da",
      ["nvim-lspconfig"]       = "278a1865-b187-8013-a3d4-c6b3c29190f1",
      ["nvim-cmp"]             = "278a1865-b187-8050-a679-f32738da7e50",
      ["nvim-tmux-navigation"] = "275a1865-b187-80c9-9aad-f4129638223f",
      ["vim-fugitive"]         = "278a1865-b187-80a3-a5ee-d76871e57751",
      -- add others as you create plugin pages
    },
    skip_builtins = true,
    skip_prefixes = { "[", "]", "g", "z" },
    skip_plug_mappings = true,
    project_plugins = { ["yazi.nvim"]=true, ["telescope.nvim"]=true },
    update_only = true, -- default: don't mass-create; update/rebind only
  },
  cond = function() return (vim.env.NOTION_API_KEY or "") ~= "" end,
  config = function(_, opts) require("notio").setup(opts) end,
}
```

Local dev path:

```lua
{
  dir = vim.fn.expand("$MATRIX") .. "/nvim/notio",
  name = "notio",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("notio").setup({
      database_id = "275a1865-b187-81b9-bc4a-fbe5d44e2911",
      app_page_id = "13fa1865-b187-815a-b3d7-f0a23559e641",
      plugin_pages = {
        ["yazi.nvim"]            = "278a1865-b187-8015-9e18-c51affadd8b1",
        ["telescope.nvim"]       = "278a1865-b187-80ac-9b86-c94087ad60da",
        ["nvim-lspconfig"]       = "278a1865-b187-8013-a3d4-c6b3c29190f1",
        ["nvim-cmp"]             = "278a1865-b187-8050-a679-f32738da7e50",
        ["nvim-tmux-navigation"] = "275a1865-b187-80c9-9aad-f4129638223f",
        ["vim-fugitive"]         = "278a1865-b187-80a3-a5ee-d76871e57751",
      },
      skip_builtins = true,
      skip_prefixes = { "[", "]", "g", "z" },
      skip_plug_mappings = true,
      project_plugins = { ["yazi.nvim"]=true, ["telescope.nvim"]=true },
      update_only = true,
    })
  end,
}
```

> Requires `NOTION_API_KEY` in your environment. `:NotioPing` will validate token + DB connection.

---

## Commands

- `:NotioSync` — run the sync plan against Notion (prompts to confirm).
- `:NotioSync dry` or `:NotioDryRun` — show a **plan buffer**: `create / update / rebind / skip`.
- `:NotioAbort` — ask the current sync to stop after the in-flight request.
- `:NotioPing` — sanity check: token owner + database reachability.
- `:NotioBackfillUID` — writes **UID** into rows that are missing it (uses the synthetic UID).
- `:NotioDebug` — opens a small buffer showing effective config toggles.

During a real sync, a **log buffer** opens (success/failure per row).

---

## Matching & upsert rules (TL;DR)

- **Stable UID**: `mode|lhs|scope` (e.g., `n|<leader>pf|Project`), where `lhs` is normalized.
- Primary match order: **UID** → **binding fingerprint** (`type|prefix|lhs`) → **Name**.
- If binding is unchanged → **skip**.  
  If binding changed → **update** (or **rebind**, marked `Changed` and optionally `Date` touched).  
- **Built-ins** (`Command = "Built in"` or empty) are always skipped and never created.
- Default guardrails:
  - `update_only = true` — won’t mass-create unless you flip it.
  - `never_create_builtins = true` — don’t create empty/“Built in” rows.
  - `skip_prefixes = { "[", "]", "g", "z" }` — drop noisy families up-front.

---

## Notion behavior

- **Application** relation is set to your `app_page_id` for every synced row (namespaces your DB).
- **Plugin** relation is set when a plugin is detected *and* you provide a page id in `plugin_pages`.
- **Action** (rich_text):  
  - First run is the LHS as code (colored).  
  - Suffix is description text (non-code).  
  - **By default, Action is only written on create** to respect manual edits.  
    Set `update_action_on_update = true` if you want it overwritten during updates.
- **Description** (rich_text): written on create. If empty, it falls back to a friendly RHS interpretation or `Command`.
- **UID** (rich_text): always written (code, blue); used to keep rows stable over time.
- **Mode** / **Platform**: multi-selects; Mode merges all modes for the same `(buffer,lhs)` into one row.
- **Scope**: `Global` / `Buffer` / `Project` (project determined by `project_plugins`).
- **Tier**: defaulted to `"A"` on create, left alone on update unless you pass one.
- **Date**: touched on create; optionally on update (see `touch_date_on_*`).

---

## Required Notion schema (properties)

| Property       | Type          | Notes                                                                 |
|----------------|---------------|-----------------------------------------------------------------------|
| **Name**       | Title         | Pretty LHS (+ short plugin label in parens when known)                |
| **Action**     | Rich text     | First run = code LHS; suffix = human text                             |
| **Description**| Rich text     | Human text; complements `Action`                                      |
| **Command**    | Rich text     | Source (“Plugin: slug” or explicit command/desc)                      |
| **UID**        | Rich text     | Code, blue; `mode|lhs|scope`                                          |
| **Application**| Relation      | Must point to your Neovim page (`app_page_id`)                        |
| **Plugin**     | Relation      | Optional per-plugin relation (via `plugin_pages`)                     |
| **Status**     | Select        | Defaults to `Active`                                                  |
| **Type**       | Select        | `leader | chord | prefix | motion | operator | command`                |
| **Category**   | Select        | e.g., `Search`, `Navigation`, `Debug`, `LSP`, etc.                    |
| **Prefix**     | Select        | `<leader>`, `g`, `z`, `:`, `none`, etc.                               |
| **Scope**      | Select        | `Global | Buffer | Project`                                           |
| **Mode**       | Multi-select  | `Normal`, `Visual`, `Insert`, `Command`, `Terminal`, `Select`, `Operator-pending` |
| **Platform**   | Multi-select  | Typically `"Linux, Windows, macOS"`                                   |
| **Tier**       | Select        | Defaults to `A` on create                                             |
| **Date**       | Date          | Touched on create                                                     |
| **Docs**       | URL           | Optional                                                              |

> Names must match exactly (you can rename in `opts.properties` later; today they’re hardcoded to these labels).

---

## Configuration

These live in `lua/notio/init.lua` defaults and can be overridden via `opts`:

- **database_id**, **app_page_id** *(required)*
- **plugin_pages**: `{ ["plugin-slug"] = "notion-page-id", ... }`
- **include_modes**: `{ "n","v","x","s","i","c","t","o" }`
- **skip_builtins**: `true`  
- **skip_plug_mappings**: `true`
- **skip_prefixes**: `{ "[", "]", "g", "z" }`
- **project_plugins**: e.g. `{ ["yazi.nvim"]=true, ["telescope.nvim"]=true }`
- **update_only**: `true` (flip to allow create)
- **update_action_on_update**: `false` (set `true` to rewrite `Action` on updates)
- **platform**: `{ "Linux", "Windows", "macOS" }`
- **status**: `"Active"`
- **rate_limit_ms**: `350`
- **notion_version**: `"2022-06-28"` (API version)

---

## Usage

1. Set `NOTION_API_KEY` in your shell (1Password/env).
2. Open Neovim.
3. `:NotioPing` → verify token & database.
4. `:NotioDryRun` → inspect plan (create / update / rebind / skip).
5. `:NotioSync` → confirm & run. Watch the log buffer.

Abort anytime with `:NotioAbort`.

---

## Heuristics (plugin & category)

- **Plugin**: inferred from description prefixes (`"DAP:"`, `"Explorer:"`, `"Yazi:"`, `"Theme:"`, `"CMP"`), RHS contents (`NvimTree`, `Yazi`, `Undotree`, `Git`), and callback origin paths (`telescope`, `lsp`, `dap`, etc.).  
- **Category**: from the plugin or description (`Search`, `Navigation`, `Debug`, `LSP`, `Windows/Tabs`, `Session`, `Git`, `Terminal`, `Clipboard`, `Editing`).

---

## Project status

This works for **my** Notion setup today. In a future release I’ll add an initializer (or `setup{}`) for folks who don’t use relations (or want different property names/shapes).

---

## Repo layout

```
notio/
├── LICENSE
├── README.md
└── lua
    └── notio
        ├── init.lua     # setup + sync commands + planning/logging
        ├── keymaps.lua  # collection, normalization, heuristics, rows
        └── notion.lua   # minimal Notion client (query/create/update/index)
```

---

## Changelog

- **0.1.1**
  - Notion sync: create/update/rebind with rich-text `Action/Description`, `UID`, relations.
  - Dry-run planner + live log buffer.
  - Backfill command to stamp UID where missing.
  - Safer defaults (`update_only`, skip built-ins/prefix families).

---

## License

MIT — see `LICENSE`.
