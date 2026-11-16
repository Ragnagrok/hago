# Hago

*[Leer en español](README.es.md)*

A prototype compiler for a language that looks like Haskell 98 but evaluates like Go: strict by
default, compiled to plain Go source, and able to call Go functions directly. The compiler is
written in Haskell.

```haskell
fibs :: [Int]
fibs = 0 : 1 : zipWith (+) fibs (tail fibs)

foreign import go "strings.ToUpper" toUpper :: String -> String

main :: IO ()
main = do
  print (take 5 (repeat 1))      -- [1,1,1,1,1]
  print (take 10 fibs)           -- [0,1,1,2,3,5,8,13,21,34]
  putStrLn (toUpper "hello")     -- HELLO
```

## The idea

Haskell is slow and hard to mix with other languages mostly because of laziness, not because of
its syntax. Hago keeps the syntax and drops the default: every expression is evaluated when it
is bound, like in Go. Laziness only exists where a type asks for it.

- **Lazy fields.** In `data [a] = [] | a : ~[a]`, the `~` marks the tail as lazy. When you
  build a list, the compiler suspends whatever goes into that field, so `repeat x = x : repeat x`
  works. Your own types can use `~` too.
- **Lazy parameters.** `(&&) :: Bool -> Lazy Bool -> Bool` makes `&&` short-circuit as a plain
  library function. The caller writes `a && b` as usual, and the compiler suspends `b` because
  of the type.
- **Type-directed insertion.** You never write delay or force yourself. If an expression is
  checked against `Lazy t`, the compiler suspends it. If a variable of type `Lazy t` is used
  where a `t` is expected, the compiler forces it. A strict function passed where one with
  `Lazy` parameters is expected (`foldr insert Leaf xs`) is wrapped automatically.

Suspensions are memoised thunks (`sync.OnceValue`), so they are evaluated at most once and are
safe to share between goroutines.

## What the Go looks like

`map` compiles to a generic Go function. Data types become a Go interface with one struct per
constructor:

```go
func map_[T_a any, T_b any](_arg0 func(T_a) T_b, _arg1 List[T_a]) List[T_b] {
	...
		if hg_v9, hg_ok := _arg1.(Cons[T_a]); hg_ok {
			x := hg_v9.F0
			xs := hg_v9.F1
			return Cons[T_b]{f(x), rt_lazy(func() List[T_b] {
				return map_[T_a, T_b](f, xs())
			})}
		}
	...
}
```

- **Polymorphism** becomes Go generics.
- **Calls** to known functions are direct Go calls. Partial application and function values use
  curried closures.
- **Self tail calls** become a `for` loop, so `filter` skips elements and accumulator loops run
  in constant stack.

## Calling Go

```haskell
foreign import go "strings.Repeat" repeatString :: String -> Int -> String
foreign import go "strconv.Atoi"   parseInt     :: String -> Either String Int
foreign import go "fmt.Println"    goPrintln    :: String -> IO ()
foreign import go "math.MaxInt32"  maxInt32     :: Int
```

- `Int`, `Bool`, `Char` and `String` are Go's `int`, `bool`, `rune` and `string`, so values cross
  the boundary unchanged.
- A Go function that returns `(T, error)` is declared as returning `Either String T`, or
  `IO (Either String T)` if it has effects.
- `IO ()` means the Go function is called for its effects and its results are ignored.
- The package is imported from the path before the last dot: `"path/filepath.Join"` imports
  `path/filepath`.
- A function declared without `IO` is a promise you make that it is pure.

## Performance

These numbers come from one machine, as a reference and not as a benchmark.

| Program | Time | Peak memory |
|---|---|---|
| `nfib 40`, hand-written Go | 0.34 s | — |
| `nfib 40`, Hago | 0.34 s | — |
| sum of the squares of the multiples of 3 up to 3,000,000, through lazy lists | 0.37 s | ~8 MB |

Strict, monomorphic code compiles to the Go you would write by hand, and runs like it. The lazy
list pipeline streams in constant memory, but every cell allocates a thunk, so it is much slower
than a Go loop.

## Using it

You need GHC (9.12 is tested) with cabal, and Go 1.21 or later.

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compile and run
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # just compile
./check.sh                                                  # every example and rejected program
```

The `examples/` folder has lazy lists, ADTs with pattern matching and guards, calls to Go, and
loops. Each example has an `.out` file with its expected output. The `rejected/` folder has
programs the type checker must refuse, each with the error it expects.

## What is there and what isn't

It is a prototype. The pipeline (layout rule, parser, Hindley-Milner inference that elaborates
into a typed core, Go generation) works from end to end, but a lot of Haskell 98 is missing.

**Supported**
- `data` with lazy fields (`~`), type signatures, multi-clause functions, guards, `where`, `let`,
  `case`, `if`, lambdas, `do` for IO, as-patterns.
- Operators with `infixl`/`infixr`/`infix` declarations, sections, backquotes, tuples of two and
  three, list literals, `[a..]` and `[a..b]`.
- Let-polymorphism at the top level, with dependency analysis of unsigned bindings.
- `foreign import go`.

**Missing**
- **Type classes.** `==`, `<`, `show` and `print` are built in and work on any non-function type
  (natively for `Int`, `Char`, `String`, structurally through reflection for everything else).
  `+` and the other arithmetic operators only take `Int`. There is no `Double` yet.
- Modules and imports, records, `newtype` semantics, list comprehensions, `type` synonyms,
  monads other than IO.
- **Local bindings are monomorphic.** Go function literals cannot be generic.
- **Polymorphic top-level values are not shared.** `xs = []` becomes a generic function and is
  re-evaluated at each use.
- **`Lazy` is a real type.** Laziness only reaches where the types carry it. For example,
  `foldr` takes `a -> Lazy b -> b` so it can stop early, and `++` suspends its second argument.
  The automatic adaptation covers passing strict functions, but you can still meet a type error
  that mentions `Lazy`.
- **Error messages are minimal** and have no source positions in the type checker.

## Layout of the code

| File | What it does |
|---|---|
| `src/Hago/Lexer.hs` | tokens and the layout rule |
| `src/Hago/Parser.hs` | Parsec over tokens, fixity resolution |
| `src/Hago/Typecheck.hs` | inference and elaboration, where `Lazy` is inserted |
| `src/Hago/Core.hs` | the typed core |
| `src/Hago/CodeGen.hs` | Go generation |
| `runtime/runtime.go` | lists, thunks, `show` and comparison, copied into every program |
| `prelude/Prelude.hgo` | the prelude, written in Hago |

## License

MIT. See [LICENSE](LICENSE).
