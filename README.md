# alder.nvim

Neovim support for [Alder](https://github.com/tapegram/alder): highlighting, indentation,
folds and textobjects from Alder's tree-sitter grammar; `alder check` diagnostics on save, with
the compiler's fixes; and the code generators (`alder new`, `edit`, `remove`, `regen`, `fill`)
with a preview of the diff before anything is written. In `.alder` buffers `gf` follows an
`import` to its file, `:make` runs `alder check` into the quickfix list, and `%` jumps between HTML tags.

The plugin never rewords the compiler: what you see is what `alder` printed.

## Requirements

- Neovim 0.11 or newer
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) on its `main` branch
- the `tree-sitter` CLI, 0.26.1 or newer: `brew install tree-sitter-cli`
- `alder` on your `PATH`, recent enough to support `alder help --json` (an alder built from the
  `m6a-grammar-nvim` branch or later; older builds exit 0 and print text, which `:checkhealth alder`
  reports as an error). Until editor support is tagged, build from `main`.

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
| `:Alder <args…>` | any `alder` command, with completion; generators preview their diff |
| `:AlderNew` | pick a generator, type its arguments, add flags, preview, apply |
| `:AlderFill[!]` | fill the typed hole under the cursor; `!` replaces the whole declaration body |

Generators refuse to run while an `.alder` buffer of the app has unsaved changes, because the
CLI edits files on disk: `:wall` first.

### Diagnostics and the quickfix list

Check-on-save publishes `alder check`'s diagnostics in the open buffers and puts those of files
that are not open in the quickfix list titled `alder check`. It replaces the quickfix list only
when the current one has that title; any other list you have is left alone.

When a generator refuses (the change would not compile), the refusal is shown as a notification
and its diagnostics go to their own quickfix list titled `alder <command>` (for example
`alder edit`). They describe the dry-run copy, not your buffers, so they are not published as
diagnostics and your `alder check` list stays in the quickfix stack.

### Filling holes

`:AlderFill` opens a scratch split for the typed hole under the cursor (or the file's only hole),
with the hole's name and type in a header. Type the expression below the header and press `<CR>`
(or `:w`) to apply it; `q` closes the scratch. The scratch is named
`alder://fill/<address>/?name`, or `alder://fill/<address>` with `!`, so each hole has its own
scratch and reopening one returns to it with your text.

`:Alder fill … -` refuses and points to `:AlderFill`: the CLI reads the expression from stdin,
which a command line cannot supply.

## Development

```sh
nvim --headless -u tests/minimal.lua -l tests/run.lua          # all tests
nvim --headless -u tests/minimal.lua -l tests/run.lua fill     # tests whose name contains "fill"
```

`NVIM_TS` points at an nvim-treesitter checkout (default: lazy.nvim's) and `ALDER_REPO` at an
alder checkout (default `~/projects/alder`); `alder` and `tree-sitter` must be on `PATH`.

## License

Apache-2.0
