# `kx.ax.qdocparser` reference

A qdoc comment parser for KDB-X in plain q.

```q
.kx.ax.qdocparser:use`kx.ax.qdocparser
it:.kx.ax.qdocparser.items[()!(); `:src]       / the parse result: every item under src, with its tags
```

## Exports

### `getFiles[recursive; paths]`

The files under `paths` that qdoc reads (names ending `.q`, `README` or `README.md`, any case), as a
table `([] name; kind; content)`, one row per file, with the same signature and result as kx.ax's qdoc
`getFiles`.

- `recursive` is a boolean: whether to walk into directories.
- `paths` is a path symbol or a list of them.
- For a directory, `name` is the path relative to it; for a file, the path as given. `kind` is `` `file``,
  and `content` is the text, lines joined with `"\n"`.
- A readme is named as kx.ax names it, after its directory alone: `<directory>/README`, or `README` at the
  root, whatever its case and whether or not it ends `.md`. So `core/sub/readme.md` is `sub/README`.

### `items[settings; src]`

The parse result: one row per item in the `.q` files of `src`, with its tags attached. The
columns are exactly the table aimeta's compiler builds from kx.ax today:

| column | type | |
|---|---|---|
| `ref` | symbol | the item's full name, such as `.demo.add` |
| `name` | symbol | its name within its module, such as `add` |
| `kind` | symbol | `` `function``, `` `data`` or `` `readme`` |
| `module` | symbol | its namespace, such as `.demo`, or the file's directory for a global item |
| `category`, `subcategory` | symbol | from the module: `.demo.x` gives `demo` and `x`; a global item is `Global` |
| `content` | string | the item's comment lines, then its source after the assignment |
| `tags` | table | `([] lines; tagType)`: each tag, in order, with the lines of its text |

- `settings` is kx.ax's settings dictionary, or `()!()` or `::` for the defaults. Any key kx.ax doesn't
  know is refused by name (`'settings: invalid flag(s): …`, kx.ax's message); its rendering keys (`out`,
  `idstyle`, `sitename` and so on) are accepted and ignored. Honoured so far:
  - `recursive` (default `1b`): walk into directories.
  - `exclude`: a like pattern, or `` (`like; pattern)``, matched against file paths and item refs; a
    match is left out, as in kx.ax. kx.ax's `` (`regex; pattern)`` form is refused: it needs a regex
    library, which kx.ax.qdocparser doesn't use.
  - `tagmap`: see below. With no `tagmap`, every tag keeps its name, registered or not. With one, tags
  map exactly as kx.ax maps them: through qdoc's own vocabulary extended by the given map (keys and values
  lower-cased, `@` added), and a tag in neither comes back with an empty `tagType`.
- A wrong call signals, naming the problem first: settings that aren't a dictionary, `src` of the wrong
  type, a path that doesn't exist, an items table without `name`, `kind` and `content`.
- `src` is a path symbol or string, a list of them, or a table `([] name; kind; content)` such as
  `getFiles` returns.
- Files go in path order, and items within a file in kx.ax's order.
- File headers are not items: see `files`.

### `files[settings; src]`

The file record, the parse result's second table: one row per `.q` file of `src`, in path order, apart from the
items, which it never changes.

| column | type | |
|---|---|---|
| `file` | symbol | the file's path, relative to the root |
| `module` | symbol | the file's directory, as kx.ax derives a file's module (`` ` `` at the root) |
| `header` | table | `([] lines; tagType)`: the file header's tags |
| `error` | table | `([] ref; qdType; errorType; error)`, kx.ax's error shape: what kx.ax passes over silently (below) |

The **header** is the comment block a file starts with (after any blank lines), when a blank line, a
statement that defines nothing, or the end of the file follows it. A block directly above a definition is
that definition's documentation, and the header is then empty. `settings` and `src` are as for `items`.

`error` holds one row per problem kx.ax passes over silently, in source order within each kind. None
changes the items, which stay kx.ax's.

| `errorType` | `qdType` | `ref` | when |
|---|---|---|---|
| `PARSE_ERROR` | `statement` | the file | a statement q doesn't accept (its brackets or quotes don't balance, or a lambda starts with an adverb, as `{/ c` does): kx.ax's parser skips it, so it yields no item |
| `UNBOUND_TAGS` | `block` | the file | a tag block, other than the header, above a statement that is no definition (an indexed assignment such as ``f[`k]:{..}`` included) or above a namespace switch: kx.ax drops it. In a file re-cut at `@kind` lines, only above a namespace switch |
| `MALFORMED_TAG` | `tag` | the item | a line of an item's documentation that starts with `@` but names no tag (`@ x`, `@1`): kx.ax reads it as text, or as a tag with no type |

`error` names the statement's first line of code, or the malformed line.

### `docItems[settings; src]`

The input kx.ax's documentation generator renders: what kx.ax's `qd.doc` hands its renderer (`i.doc`)
after its own parse, so that kx.ax can render from this parse instead and write the same Markdown.

| column | type | |
|---|---|---|
| `ref`, `name`, `kind`, `module`, `category`, `subcategory` | symbol | as for `items` |
| `content` | string | as for `items`; a readme's is its text |
| `parameters` | list of strings | a function's parameters, as kx.ax's renderer finds them (below) |

- The readmes come first, ordered by `ref`, as rows of kind `` `file`` named `README`, with their directory as
  module and subcategory and `Global` as category. Then the items, in `items`'s order, without tags: the
  renderer reads them from `content`.
- A function's `parameters` are the names in the parameter list of the lambda its body starts with, in
  order, as kx.ax's `getParams` finds them: a projection or application such as `{[a;b] …}[1]` has its
  lambda's; a lambda with no list, or `[]`, has none (no implicit `x`, `y`, `z`); data and readmes have
  none, `()`. They're what kx.ax's renderer checks `@param` tags against (`checkParams`), so it need not
  parse function bodies itself. kx.ax's own seven columns come first, so code that reads them by position
  is unaffected.
- `exclude` isn't applied: kx.ax's renderer applies it. `settings` and `src` are otherwise as for `items`.
- In kx.ax 1.2.2, `qd.doc[settings; src]` is `i.doc[settings] pre.file.toArtifacts lib.build.artifacts
  getFiles[…]`; `i.doc[settings] docItems[settings; src]` renders the same documentation.

### `parameters[code]`

The parameters kx.ax's `getParams` finds in a piece of q code, by the rule `docItems` uses: the names in
the parameter list of the lambda the code's body starts with (its body being the code after its leading
comment header), as a list of strings, or `()`. `docItems` applies it to each function; a documentation
generator that checks `@param` tags against code it holds as text (a whole file, say) can call it
directly instead of parsing the code.

