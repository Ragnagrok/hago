# Hago for VS Code

Highlighting for `.hgo` files, comments, brackets and indentation, and the type errors of
`hago check` shown in the editor every time a file is saved.

## Installing

The extension is plain JavaScript with no dependencies and no build step, so VS Code can load
this folder as it is. Link it into VS Code's extensions folder and restart VS Code (or run
*Developer: Reload Window*):

```sh
ln -s "$PWD/editors/vscode" ~/.vscode/extensions/ragnagrok.hago-0.1.0
```

On Windows the folder is `%USERPROFILE%\.vscode\extensions`. For VSCodium it is
`~/.vscode-oss/extensions`. A link keeps the extension up to date with the repository; copying the
folder works too.

To install it as a package instead, `npx @vscode/vsce package` in this folder makes a `.vsix`,
which *Extensions: Install from VSIX...* installs.

## Errors on save

The extension runs `hago check FILE` when a `.hgo` file is opened and whenever it is saved, and
shows the error it prints at the place it names, underlined as far as the marks under the source
go. An error in a module the file imports is shown in that module, and also on the first line of
the file that was saved. `hago check` stops at the first error, so there is at most one.

It needs the `hago` binary. Build it with `cabal build` in the repository, and either put it on
the `PATH` (`cabal install` copies it to `~/.cabal/bin`) or give its full path in the setting
`hago.path` (`cabal list-bin hago` prints it).

| Setting | Default | |
| --- | --- | --- |
| `hago.path` | `hago` | the hago command: a name on the `PATH`, or the binary's full path |
| `hago.checkOnSave` | `true` | check on open and on save; the command *Hago: Check this file* checks anyway |

What `hago check` printed is also in the *Hago* output panel.

## Highlighting

`syntaxes/hago.tmLanguage.json` is a TextMate grammar (scope `source.hago`), based on Haskell's,
with Hago's own forms:

- `foreign import go "strings.Repeat" repeatString :: ...` and `foreign import go type "[]" Vector a`:
  the Go symbol is a string scoped `string.quoted.double.go-symbol.hago`, and the name declared
  is a function or a type;
- `Lazy` and the `~` of a lazy field (`a : ~[a]`, `tailS :: ~(Stream a)`) are
  `storage.modifier.lazy.hago`, so a theme shows where laziness is;
- a field read with a dot, `p.name`, `p.home.x` and the section `(.name)`, is
  `variable.other.member.hago`, while `f . g`, with spaces, is the composition operator;
- qualified names (`Map.insert`), record fields in declarations, `deriving` lists, signatures
  and type annotations.

Other tools that read TextMate grammars can use the same file. Those built on vscode-textmate,
such as Shiki, and GitHub's Linguist read the JSON as it is. TextMate, Sublime Text and syntect
(and so `bat`) read the property-list form, which Python makes from the JSON:

```sh
python3 -c 'import json, plistlib, sys; plistlib.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "wb"))' \
  syntaxes/hago.tmLanguage.json hago.tmLanguage
```

`language-configuration.json` has the comments (`--` and `{- -}`, which *Toggle Line Comment*
uses), the brackets, folding by indentation, and indentation that goes in after a line that
ends in `where`, `do`, `of`, `let`, `=`, `->` or an open bracket. Tabs are off for `.hgo`
files and the indentation is two spaces: the layout rule counts a tab as up to eight columns,
so spaces keep the blocks where they look.
