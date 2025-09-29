# notio

**neovim keymaps → notion, on demand.**  
Export all your custom keybindings from your Neovim config and import them into a Notion database as a tidy, searchable table.

> Designed to live at `$MATRIX/nvim/notio` and to be used as a regular Neovim plugin.

---

## What it does

- Scans **all modes** (n, v, x, s, i, c, t, o) for keymaps (global + loaded buffer‑locals).
- **Deduplicates** identical `(buffer, mode, lhs)` entries.
- **Guesses plugin + category** using description/rhs/origin heuristics (e.g., Telescope, NvimTree).
- Emits a **Notion‑friendly CSV** with the exact columns your database expects.
- Adds a `:ExportKeysNotionCSV {optional_path}` Neovim command.
- Defaults to `~/Documents/Scratch/nvim_keybinds_notion.csv` if no path is given.

The implementation is a straight port of your working script into a plugin module (`lua/notio/init.lua`) plus a lightweight loader (`plugin/notio.lua`) that registers the user command.

---

## Install

Place this repo at: **`$MATRIX/nvim/notio`**

With **lazy.nvim** (example when you publish to GitHub as `suhailphotos/notio`):

```lua
{
  "suhailphotos/notio",
  config = function()
    -- no setup needed yet; command is auto-registered
  end,
}
```

Local dev path (lazy.nvim):

```lua
{
  dir = vim.fn.expand("$MATRIX") .. "/nvim/notio",
  name = "notio",
}
```

> Packer or other managers work the same—ensure `plugin/notio.lua` is on `runtimepath`.

---

## Usage

Inside Neovim:

```vim
:ExportKeysNotionCSV
:ExportKeysNotionCSV ~/Documents/Scratch/my_keymaps.csv
```

- If no path is provided, it writes to `~/Documents/Scratch/nvim_keybinds_notion.csv`.
- You’ll see a `vim.notify` with the final path and row count when it completes.

### Headless (CLI) export (optional)

Create a tiny wrapper script named `notio` somewhere on your `$PATH`:

```bash
#!/usr/bin/env bash
set -euo pipefail
OUT="${1:-${NOTIO_OUT:-$HOME/Documents/Scratch/nvim_keybinds_notion.csv}}"
nvim --headless +'lua require("notio").export_notion_csv([['"'"'${OUT}'"'"']])' +qa
echo "wrote: ${OUT}"
```

Then run:
```bash
notio                         # default path
notio ~/Documents/Scratch/my_keymaps.csv
```

---

## Output schema (CSV)

Columns (order matters and matches your Notion database import):

```
Name,Action,Application,Application 1,Category,Command,Date,Description,Docs,
Mode,Platform,Plugin,Plugin 1,Prefix,Scope,Status,Tier,Type
```

### Column notes

- **Name**: Pretty LHS; if a known plugin is detected, appends short label `(Telescope|NvimTree|…)`.
- **Action**: Either `"<lhs> <desc>"` if a description exists, else the lhs itself.
- **Application**: Pre-filled with your Notion page reference for Neovim.
- **Docs / Plugin 1**: Notion page links per plugin (from a local map).
- **Mode**: Expanded human name (Normal, Visual, …).
- **Platform**: `"Linux, Windows, macOS"` by default.
- **Prefix**: `<leader>`, `g`, `t`, brackets, quotes, etc., or `"none"`.
- **Scope**: `"Global"` or `"Buffer"` (buffer-local maps are treated as Buffer).
- **Type**: `"leader" | "chord" | "prefix" | "motion" | "operator" | "command"`.

---

## Heuristics (how plugins/categories are guessed)

`guess_plugin(desc, rhs, origin, buffer, mode)` checks, in order:

1. **Description cues** (e.g., `DAP:`, `Explorer:`, `Yazi:`, `Theme:`).
2. **RHS strings** (e.g., contains `NvimTree`, `Yazi`, `Undotree`, `Git`).
3. **Lua origin file** (source path from `debug.getinfo`), e.g. `lazy/telescope.lua`.

If none match, it returns `nil` and the row is labeled **Custom configuration** (or **Requires LSP attached** for certain buffer-local/LSP cases).

`guess_category(plugin, desc, lhs)` then maps to **Search / Navigation / Debug / LSP / Editing / Windows/Tabs / Session / Git / Terminal / Clipboard / Custom configuration**.

---

## Configuration (lightweight)

The following tables live near the top of `lua/notio/init.lua` and can be edited or extended in-place:

- `NEOVIM_NOTION` (your Neovim page label + URL shown in the **Application** column)
- `DEFAULT_PLATFORM`
- `NOTION_LINKS` (plugin slug → Notion page link label)
- `PLUGIN_SHORT` (slug → short label for `Name` parentheses)
- `PLUGIN_CATEGORY` (slug → category)

> In a later iteration we can add a `require("notio").setup{ ... }` to set these at runtime via `vim.g` or a Lua table—today the port keeps it simple and explicit.

---

## Repo layout

```
notio/
├─ README.md
├─ LICENSE            # MIT
├─ lua/
│  └─ notio/
│     └─ init.lua     # the exporter module (ported code lives here)
└─ plugin/
   └─ notio.lua       # registers :ExportKeysNotionCSV and calls module
```

Minimal `plugin/notio.lua` shim (for reference):

```lua
-- plugin/notio.lua
pcall(function()
  vim.api.nvim_create_user_command("ExportKeysNotionCSV", function(a)
    require("notio").export_notion_csv(a.args ~= "" and a.args or nil)
  end, { nargs = "?" })
end)
```

---

## Import into Notion

1. Open your **KeyBindings** database.
2. Click **… > Merge with CSV** (or **New database > CSV** for first import).
3. Map columns 1:1 (names match your schema).
4. After import, adjust **Tier**, **Status**, or additional relations as needed.

> Tip: Keep the same column order to make imports seamless. For incremental updates, you can filter/merge by **Name + Mode + Prefix** or your preferred composite key.

---

## Roadmap

- **Direct Notion API export** (no CSV) using `notion_client` with token from 1Password.
- **Incremental sync** (detect changes vs last export; upsert by composite key).
- **Plugin analytics** (e.g., orphaned maps, conflicting prefixes).
- **Config-as-code** (`setup{}`) + user autocommands.

---

## License

MIT — see `LICENSE`.

---

## Acknowledgements

Built for a Neovim + Notion workflow where clarity and searchability matter.
