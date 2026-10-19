# alder.nvim

Neovim support for [Alder](https://github.com/tapegram/alder): highlighting, indentation,
folds and textobjects from Alder's tree-sitter grammar; the language server (`alder lsp`) for
diagnostics while you type, hover, go to definition, references, completion and code actions;
and the code generators, planned by the server and applied to your buffers after a preview of
the diff. In `.alder` buffers `gf` follows an
`import` to its file, `:make` runs `alder check` into the quickfix list, and `%` jumps between HTML tags.

The plugin never rewords the compiler: what you see is what `alder` printed.

## Requirements

- Neovim 0.11 or newer
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) on its `main` branch
- the `tree-sitter` CLI, 0.26.1 or newer: `brew install tree-sitter-cli`
- `alder` on your `PATH` with the language server: `alder lsp` must exist, and `alder help --json`
  must print JSON. Until editor support is tagged, build from `main`
  (`go install ./cmd/alder`). Older builds lack `lsp`; `:checkhealth alder` says what is missing,
  and `opts.lsp = false` keeps the plugin working on the CLI alone (`alder check` on save).

## Install

lazy.nvim:

```lua
{
  'tapegram/alder.nvim',
  lazy = false, -- it is small, and it must register the parser before :TSInstall
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  opts = {},
}
```

AstroNvim, `lua/plugins/alder.lua`:

```lua
---@type LazySpec
return {
  { 'tapegram/alder.nvim', lazy = false, opts = {} },
  {
    'AstroNvim/astrocore',
    opts = function(_, opts)
      opts.treesitter = opts.treesitter or {}
      opts.treesitter.ensure_installed =
        require('astrocore').list_insert_unique(opts.treesitter.ensure_installed, { 'alder' })
    end,
  },
}
```

Then `:TSInstall alder`, and `:checkhealth alder`.

## Options

```lua
require('alder').setup({
  cmd = 'alder',        -- the alder binary
  check_on_save = true, -- run alder check after writing an .alder file
  preview = true,       -- generators show their diff first; <CR> applies, q discards
  lsp = true,           -- start `alder lsp` for .alder buffers; false keeps CLI mode
  keys = {              -- buffer-local maps in .alder files; each can be false
    actions = '<leader>aa',
    diagnostics = '<leader>ac',
    explain = '<leader>ae',
    run = '<leader>ar',
  },
  revision = nil,       -- install the grammar from this tag of tapegram/alder, e.g. 'v0.2.0'
  path = nil,           -- install the grammar from a local alder checkout (see below)
})
```

The grammar lives in the alder repository (`tree-sitter-alder/`) and changes with the language.
By default `:TSInstall alder` takes it from `main`; set `revision` to the tag of the `alder` you
run so the grammar matches your compiler.

**Grammar development:** set `path = '~/projects/alder'` (the checkout's root, not its
`tree-sitter-alder/` directory), edit the grammar or its queries there, then `:TSUpdate alder`.

## Commands

| Command | What it does |
|---|---|
| `:AlderCheck` | `alder check`: diagnostics in open buffers, other files in the quickfix list |
| `:AlderFix` | apply the compiler's fix for the diagnostic under the cursor |
| `:AlderExplain [code]` | `alder explain` for the code (default: the diagnostic under the cursor) |
| `:AlderActions` | the code actions at the cursor: the compiler's fixes, then the generators (`<leader>aa`) |
| `:AlderGenerate [id]` | pick any generator (`new msg`, `edit table`, ...) and answer its fields; those that apply at the cursor come first |
| `:AlderDiagnostics` | the buffers' diagnostics in the quickfix list (`<leader>ac`) |
| `:Alder <args…>` | any `alder` command, with completion; it writes to disk through the CLI |

## Keys

In `.alder` buffers:

| Key | What it does |
|---|---|
| `<leader>aa` | code actions at the cursor: fixes first, then generators |
| `<leader>ac` | diagnostics to the quickfix list |
| `<leader>ae` | explain the diagnostic under the cursor |
| `<leader>ar` | `alder run` |

Each can be set to `false` in `opts.keys`. With which-key, `<leader>a` is the group "alder".

Neovim maps these LSP keys itself (0.11+): `K` hover, `grr` references, `gra` code actions
(it opens the same flow as `<leader>aa`), `<C-]>` go to definition through the LSP `tagfunc`.
It does **not** map `gd`; add it if you want it:

```lua
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(ev)
    local c = vim.lsp.get_client_by_id(ev.data.client_id)
    if c and c.name == 'alder' then
      vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = ev.buf })
      -- LSP completion is off by default; this turns it on (or use blink.cmp / nvim-cmp)
      vim.lsp.completion.enable(true, c.id, ev.buf, { autotrigger = true })
    end
  end,
})
```

`gd` on a standard-library name answers nothing (those files are embedded); `K` still shows the
signature.

## Diagnostics

The server checks the buffer's text as `alder check` would a moment after you stop typing, saved
or not, and publishes the result; a typed hole (W0002) is a hint. With `opts.lsp = false`, or
when the server is not attached, `alder check` runs on save instead and puts the diagnostics of
files that are not open in the quickfix list titled `alder check` (it replaces the quickfix list
only when the current one has that title).

If the server stops, the plugin says `alder lsp stopped — :checkhealth alder`. A request with
no server to answer says `alder: the language server is not attached (:checkhealth alder)`.
`<leader>ae` with nothing to explain says `alder: no diagnostic under the cursor`.

## Applying generators

`<leader>aa` (or `gra`, or `:AlderGenerate`) asks for the generator's remaining fields, shows
the diff, and on `<CR>` applies it; `q` discards. The server plans the change on a copy of
your app, built from your buffers, and the plugin puts the result into **buffers**:

- Nothing is written until you save. `:w` saves one file, `:wall` all of them; `u` undoes an
  apply in each buffer.
- A new file arrives as an unsaved buffer and its directory is created on the first `:w`.
- The one thing the plugin asks is a deletion (`remove page`, `remove table`): a buffer edit
  cannot delete a file, and undo cannot bring it back. The prompt is
  `Delete <path> from disk? undo cannot restore it` with `Yes` and `No`; on `No` nothing is applied.
- If a file changed between the plan and `<CR>`, nothing is applied:
  `alder: <path> changed since planning; nothing applied`. On success:
  `alder: applied <generator>: <files>`.
- When no generator applies at the cursor you get
  `alder: nothing applies here; the first line that has something is <n>`.
- A generator that adds a table also writes `migrations/*`. The checker reads migrations from
  disk, so E0019 ("the schema changed since migration ...") shows until those buffers are saved.
  `:wall`, and it goes away; `alder check` from the shell is then clean.
- When a generator refuses (the change would not compile), the refusal is shown as a
  notification and its diagnostics go to their own quickfix list titled `alder <command>`. They
  describe the dry-run copy, so they are not published as diagnostics.

`:Alder new page ...` and the other CLI generators still write straight to disk, and refuse
to run while an `.alder` buffer of the app has unsaved changes: `:wall` first.

## Filling holes

A hole is just text. Put `?count` where an expression goes: the server shows it as a hint, `K`
on it shows the type it must have, and completion at the hole lists the names in scope, those
whose type fits first. Picking one replaces the whole `?name`. `alder fill` stays a
command-line tool (`alder fill --list`, `alder fill <Module>.<decl> -` for an agent); the
plugin has no command for it.

## Development

```sh
nvim --headless -u tests/minimal.lua -l tests/run.lua          # all tests
nvim --headless -u tests/minimal.lua -l tests/run.lua keys     # tests whose name contains "keys"
```

`NVIM_TS` points at an nvim-treesitter checkout (default: lazy.nvim's) and `ALDER_REPO` at an
alder checkout (default `~/projects/alder`); `alder` and `tree-sitter` must be on `PATH`.

## License

Apache-2.0
