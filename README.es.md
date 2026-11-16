# Hago

*[Read in English](README.md)*

Un prototipo de compilador para un lenguaje que se ve como Haskell 98 pero se evalúa como Go:
estricto por defecto, compilado a código Go común y capaz de llamar funciones de Go directamente.
El compilador está escrito en Haskell.

```haskell
fibs :: [Int]
fibs = 0 : 1 : zipWith (+) fibs (tail fibs)

foreign import go "strings.ToUpper" toUpper :: String -> String

main :: IO ()
main = do
  print (take 5 (repeat 1))      -- [1,1,1,1,1]
  print (take 10 fibs)           -- [0,1,1,2,3,5,8,13,21,34]
  putStrLn (toUpper "hola")      -- HOLA
```

## La idea

Lo que hace lento a Haskell, y difícil de mezclar con otros lenguajes, es sobre todo la pereza,
no la sintaxis. Hago conserva la sintaxis y cambia el comportamiento por defecto: cada expresión
se evalúa cuando se liga, como en Go. La pereza existe sólo donde un tipo la pide.

- **Campos perezosos.** En `data [a] = [] | a : ~[a]`, el `~` marca la cola como perezosa. Al
  construir una lista, el compilador suspende lo que va en ese campo, así que
  `repeat x = x : repeat x` funciona. Los tipos propios también pueden usar `~`.
- **Parámetros perezosos.** `(&&) :: Bool -> Lazy Bool -> Bool` hace que `&&` cortocircuite
  siendo una función común de biblioteca. Quien llama escribe `a && b` como siempre, y el
  compilador suspende `b` porque lo dice el tipo.
- **Inserción guiada por tipos.** Nunca se escribe el retraso ni el forzado a mano. Si una
  expresión se chequea contra `Lazy t`, el compilador la suspende. Si una variable de tipo
  `Lazy t` se usa donde se espera un `t`, el compilador la fuerza. Una función estricta pasada
  donde se espera una con parámetros `Lazy` (`foldr insert Leaf xs`) se adapta sola.

Las suspensiones son thunks memoizados (`sync.OnceValue`): se evalúan como mucho una vez y se
pueden compartir entre goroutines.

## Cómo queda el Go

`map` se compila a una función genérica de Go. Los tipos de datos son una interfaz de Go con un
struct por constructor:

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

- **El polimorfismo** se traduce a genéricos de Go.
- **Las llamadas** a funciones conocidas son llamadas directas de Go. La aplicación parcial y las
  funciones como valores usan closures currificadas.
- **Las llamadas de cola a sí misma** se vuelven un `for`, así que `filter` saltea elementos y
  los loops con acumulador corren con pila constante.

## Llamar a Go

```haskell
foreign import go "strings.Repeat" repeatString :: String -> Int -> String
foreign import go "strconv.Atoi"   parseInt     :: String -> Either String Int
foreign import go "fmt.Println"    goPrintln    :: String -> IO ()
foreign import go "math.MaxInt32"  maxInt32     :: Int
```

- `Int`, `Bool`, `Char` y `String` son `int`, `bool`, `rune` y `string` de Go, así que los
  valores cruzan la frontera sin conversión.
- Una función de Go que devuelve `(T, error)` se declara como `Either String T`, o
  `IO (Either String T)` si tiene efectos.
- `IO ()` significa que se la llama por sus efectos y se ignoran sus resultados.
- El paquete se importa desde la ruta anterior al último punto: `"path/filepath.Join"` importa
  `path/filepath`.
- Declarar una función sin `IO` es una promesa tuya de que es pura.

## Performance

Son números de una sola máquina, como referencia y no como benchmark.

| Programa | Tiempo | Memoria máxima |
|---|---|---|
| `nfib 40`, Go escrito a mano | 0,34 s | — |
| `nfib 40`, Hago | 0,34 s | — |
| suma de los cuadrados de los múltiplos de 3 hasta 3.000.000, con listas perezosas | 0,37 s | ~8 MB |

El código estricto y monomórfico se compila al Go que escribirías a mano, y rinde igual. La
cadena de listas perezosas corre en memoria constante, pero cada celda reserva un thunk, así que
es mucho más lenta que un loop de Go.

## Uso

Hace falta GHC (probado con 9.12) con cabal, y Go 1.21 o posterior.

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compilar y correr
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # sólo compilar
./check.sh                                                  # todos los ejemplos y los rechazados
```

En `examples/` hay listas perezosas, ADTs con pattern matching y guardas, llamadas a Go y loops.
Cada ejemplo tiene un `.out` con la salida esperada. En `rejected/` hay programas que el type
checker tiene que rechazar, cada uno con el error que espera.

## Qué hay y qué no

Es un prototipo. El pipeline completo funciona de punta a punta: regla de layout, parser,
inferencia Hindley-Milner que elabora a un core tipado, y generación de Go. Pero falta mucho de
Haskell 98.

**Soportado**
- `data` con campos perezosos (`~`), firmas de tipos, funciones con varias cláusulas, guardas,
  `where`, `let`, `case`, `if`, lambdas, `do` para IO, as-patterns.
- Operadores con declaraciones `infixl`/`infixr`/`infix`, secciones, backquotes, tuplas de dos y
  de tres, listas literales, `[a..]` y `[a..b]`.
- Polimorfismo de let en el nivel superior, con análisis de dependencias de las definiciones sin
  firma.
- `foreign import go`.

**Falta**
- **Type classes.** `==`, `<`, `show` y `print` son primitivas y andan con cualquier tipo que no
  sea una función (de forma nativa para `Int`, `Char` y `String`, y estructuralmente por
  reflexión para el resto). `+` y los demás operadores aritméticos sólo toman `Int`. Todavía no
  hay `Double`.
- Módulos e imports, records, la semántica de `newtype`, listas por comprensión, sinónimos con
  `type`, mónadas que no sean IO.
- **Las definiciones locales son monomórficas.** Las funciones literales de Go no pueden ser
  genéricas.
- **Los valores polimórficos del nivel superior no se comparten.** `xs = []` se vuelve una
  función genérica y se reevalúa en cada uso.
- **`Lazy` es un tipo de verdad.** La pereza sólo llega hasta donde la llevan los tipos. Por
  ejemplo, `foldr` toma `a -> Lazy b -> b` para poder cortar antes, y `++` suspende su segundo
  argumento. La adaptación automática cubre el caso de pasar funciones estrictas, pero igual
  puede aparecer un error de tipos que mencione `Lazy`.
- **Los mensajes de error son mínimos** y el type checker no da posiciones en el código.

## Organización del código

| Archivo | Qué hace |
|---|---|
| `src/Hago/Lexer.hs` | tokens y regla de layout |
| `src/Hago/Parser.hs` | Parsec sobre tokens, resolución de fixity |
| `src/Hago/Typecheck.hs` | inferencia y elaboración, donde se inserta `Lazy` |
| `src/Hago/Core.hs` | el core tipado |
| `src/Hago/CodeGen.hs` | generación de Go |
| `runtime/runtime.go` | listas, thunks, `show` y comparación; se copia en cada programa |
| `prelude/Prelude.hgo` | el prelude, escrito en Hago |

## Licencia

MIT. Ver [LICENSE](LICENSE).
