# Hago

*[Read in English](README.md)*

Un prototipo de compilador para un lenguaje que se ve como Haskell 98 pero se evalúa como Go:
estricto por defecto, compilado a código Go común y capaz de llamar funciones de Go directamente.
El compilador está escrito en Haskell.

```haskell
fibs :: [Int]
fibs = 0 : 1 : zipWith (+) fibs (drop 1 fibs)

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

## Type classes

```haskell
class Show a => Shape a where
  area :: a -> Double
  name :: a -> String
  name x = show x                      -- un método por defecto

data Square = Square Double deriving (Show)
data Pair a = Pair a a deriving (Show)

instance Shape Square where
  area (Square s) = s * s

instance Shape a => Shape (Pair a) where
  area (Pair x y) = area x + area y

describe :: Shape a => a -> String
describe s = name s ++ " has area " ++ show (area s)
```

También hay clases sobre constructores de tipos, como `Functor`, `Applicative`, `Monad`,
`Foldable` y `Traversable`, y se pueden escribir instancias propias:

```haskell
data State s a = State (s -> (a, s))

instance Monad (State s) where
  m >>= k = State (\s -> case runState m s of
                           (a, s') -> runState (k a) s')

-- get y put como en examples/monads.hgo
label :: Tree a -> State Int (Tree (Int, a))
label t = traverse step t
  where
    step x = do
      n <- get
      put (n + 1)
      pure (n, x)
```

- **`do` funciona en cualquier mónada.** En IO se compila a Go secuencial, y en el resto a
  `>>=`. `p <- e` puede ligar un patrón.
- **Los tipos de datos pueden tomar un constructor de tipos,** así que se pueden escribir
  transformadores de mónadas: `data StateT s m a = StateT (s -> m (a, s))`. Go no tiene ese
  tipo de parámetros, así que cada uso tiene su propio tipo de Go: `StateT s IO a` se vuelve
  `StateT__IO[S, A]`, generado sólo para las combinaciones que el programa usa.
  `examples/transformers.hgo` define `StateT`, `ExceptT`, `MonadTrans` y `MonadIO`, y corre una
  máquina de pila sobre `StateT [Int] (ExceptT String IO)`.
- **Las instancias pueden ser aplicaciones parciales,** como `Functor (Either e)`,
  `Monad ((->) r)` (un *reader*) y `Monoid w => Monad ((,) w)` (un *writer*).
- **`deriving (Eq, Ord, Show)`** se expande a instancias comunes antes del type checking.
- **Los literales enteros** están sobrecargados con `fromInteger`, y los decimales con
  `Fractional`. Los tipos ambiguos caen por defecto en `Int`, o en `Double` si hay `Fractional`
  o `Floating`, como en Haskell. Las definiciones sin firma y sin parámetros siguen la
  monomorphism restriction.

### Cómo se compilan

Las clases se compilan por **especialización**, como en Rust y MLton:

- **Toda función con restricciones, o polimórfica sobre un constructor de tipos, es una
  plantilla.** El compilador genera una copia por cada instancia o constructor con que se usa:
  `nfib :: (Ord a, Num a) => a -> a` usada en `Int` se vuelve `nfib__Int`, y `traverse` usado
  en `State Int` tiene su propia copia.
- **Cada llamada a un método es una llamada directa a la función de la instancia,** que Go
  inlinea cuando es chica: `n + 1` sobre `Int` termina siendo un `+` común.
- **No existe ningún diccionario en tiempo de ejecución.** Los genéricos de Go son sobre tipos,
  no sobre constructores de tipos (no existe `F[_]`), así que un diccionario de `Functor f` no
  podría existir de todos modos.
- **Las variables de tipo sin restricciones siguen siendo genéricos de Go,** así que `map` sigue
  siendo una sola función.

## Una jerarquía sin los errores de Haskell

El Prelude conserva las clases de Haskell, pero no las decisiones que el propio Haskell tuvo que
deshacer o con las que todavía convive:

- **`Functor => Applicative => Monad` desde el principio.** `return` no es un método, es `pure`.
- **`Semigroup => Monoid`.** `<>` es la única forma de combinar, y no existe `mappend`.
- **`fail` está en `MonadFail`,** no en `Monad`.
- **Plegar y recorrer pasa por `Foldable` y `Traversable`.** `sum`, `elem`, `length`, `mapM_` y
  compañía funcionan con cualquier `Foldable`. `traverse_` sólo pide `Applicative`, y `mapM` es
  simplemente `traverse`. `mapM_` y `forM_` usan `>>=`, como en base, lo que deja el resto de un
  loop suspendido hasta que se ejecuta.
- **`Num` es un anillo:** `+`, `-`, `*`, `negate` y `fromInteger`. `abs` y `signum` sólo tienen
  sentido con un orden, así que son funciones sobre `(Ord a, Num a)`. `Num` no exige `Eq` ni
  `Show`. `Integral` exige `Ord`, y `Floating` tiene `sqrt`, `pi` y el resto.
- **Sin funciones parciales en el Prelude.** `head`, `tail`, `!!`, `maximum` y `minimum`
  devuelven `Maybe`, y `read` también: `read "4x" :: Maybe Int` es `Nothing`, no un error en
  tiempo de ejecución.
- **Sin instancia de `Foldable` para tuplas,** así que `length (1, 2)` es un error de tipos, no
  `1`.
- **`Enum` es total.** `toEnum`, `succ` y `pred` devuelven `Maybe`, así que `succ maxBound` es
  `Nothing` en lugar de un error en tiempo de ejecución, y `[x ..]` sobre un tipo acotado
  termina en su último valor.
- **Sin `Enum Double`.** En Haskell, `[0.1, 0.2 .. 1.0]` se pasa de `1.0`, porque un rango de
  números de punto flotante no puede ser exacto. Hago lo rechaza y sugiere mapear sobre un rango
  de `Int`.
- **`foldl` es estricto,** porque el lenguaje lo es, así que no hace falta `foldl'`.
- **`String` no es `[Char]`.**

### Loops y la pila

Un lenguaje estricto no puede contar con la pereza para que la recursión monádica no crezca, y
Go no elimina llamadas de cola. Hago lo resuelve de dos maneras, siguiendo a PureScript:

- **IO usa un trampolín.** Ejecutar una acción devuelve su resultado o la acción siguiente, y el
  runtime itera sobre ellas. Un bloque `do` que termina en otra acción, `>>=` y `*>` no consumen
  pila: `loop n = do { ...; loop (n + 1) }` corre para siempre, y `mapM_` sobre un millón de
  elementos corre en memoria constante, en IO y en transformadores sobre IO como
  `StateT s IO`.
- **`MonadRec` y `tailRecM`** corren loops con pila constante en otras mónadas. `IO`, `Maybe` y
  `Either e` tienen instancia, se puede escribir una para una mónada propia (ver
  `examples/monads.hgo`), y `forever` está construido encima.

## Módulos

```haskell
module Data.Stack (Stack, empty, push, pop) where   -- Stack es abstracto

import qualified Data.Stack as S
import Geometry.Shapes (Shape(..), area)
import Geometry.Shapes hiding (perimeter)

module Geometry (module Geometry.Shapes, scale) where   -- reexporta Geometry.Shapes
```

- **Un módulo `A.B` vive en `A/B.hgo`,** junto al archivo principal, que es `Main`.
- **Las listas de exportación e importación, `qualified`, `as` y `hiding`** funcionan como en
  Haskell. Un tipo exportado sin `(..)` es abstracto.
- **Un módulo puede reexportar** lo que importa, nombre por nombre o un módulo entero con
  `module M`. Dos cosas distintas con el mismo nombre en una lista de exportación son un error.
- **Las definiciones propias tapan a las importadas,** así que un módulo puede definir su propio
  `toList`. Dos importaciones que le dan significados distintos a un mismo nombre son ambiguas
  sólo donde ese nombre se usa.
- **Las instancias son globales,** como en Haskell.

Un paso de renombrado resuelve cada nombre a uno interno, calificado por su módulo
(`Geometry.Shapes.area`). Después de ese paso el compilador trabaja sobre un programa plano, y la
salida en Go sigue siendo un solo archivo.

## Records, sin los errores de Haskell

```haskell
data Point = Point { x, y :: Double }
data Person = Person { name :: String, age :: Int, home :: Point }
data Company = Company { name :: String, staff :: [Person] }   -- otra vez name: no hay problema

ana = Person { name = "Ana", age = 30, home = Point { x = 1.0, y = 2.0 } }

ana.name                      -- "Ana"
map (.age) acme.staff         -- un campo como función
ana { age = 31 }              -- una actualización
ana { home.x = 3.5 }          -- la actualización de un campo de un campo
area (Circle { radius }) = 3.0 * radius * radius   -- matchear algunos campos
```

Los records de Haskell tienen problemas conocidos. Hago evita cada uno:

- **Los campos no son funciones.** En Haskell un campo declara una función de nivel superior,
  así que dos tipos del mismo módulo no pueden tener los dos un `name`, y nadie más puede usar
  ese nombre. En Hago un campo pertenece a su tipo. Se lee con `p.name`, y el tipo de `p` dice
  de qué `name` se trata. Cuando hace falta una función, `(.name)` es una.
- **Leer un campo no puede fallar.** Haskell acepta `radius s` para un `Square` y falla en
  tiempo de ejecución. Hago acepta `s.radius`, y la actualización de `radius`, sólo si todos los
  constructores del tipo tienen ese campo. Si no, pide matchear sobre el constructor.
- **Construir un record exige todos los campos.** Haskell sólo avisa que falta un campo y deja un
  error en su lugar. Hago no lo compila.
- **Los campos respetan la abstracción.** Se ven donde se ven los constructores del tipo, así que
  un tipo exportado sin `(..)` también esconde sus campos.
- **Las actualizaciones anidadas son cortas.** `p { home.x = 3.5 }` en lugar de
  `p { home = (home p) { x = 3.5 } }`.

Los *puns* funcionan en patrones y al construir (`Person { name, age }`), y `C {}` matchea
cualquier `C`. Como con `OverloadedRecordDot` de GHC, un punto sin espacio de ningún lado es un
acceso a un campo, así que `f.g` ya no es una composición; se escribe `f . g`.

Si todavía no se conoce el tipo de `p` y hay dos tipos con ese campo, el compilador pide una
anotación en lugar de adivinar. Para que eso pase poco, los argumentos que son lambdas se
chequean después que los demás: en `map (.name) people`, el tipo de `people` se conoce antes de
chequear `(.name)`.

Como en Haskell 98, una actualización puede cambiar un parámetro de tipo que sólo aparece en
los campos que se actualizan: darle un string al `item` de una `Box Int` da una `Box String`.

## Los newtypes son gratis

En un lenguaje estricto, `newtype` significa lo mismo que `data` con un constructor y un campo.
Lo que agrega la palabra clave es la promesa de que el envoltorio no cuesta nada, y Hago la
cumple. Después de la especialización, cuando cada instancia ya se eligió por tipo, cada newtype
se reemplaza por el tipo que envuelve. Desaparecen el envolver, el desenvolver y el tipo de Go.
`newtype Meters = Meters Double` es un `float64` en el Go generado, y conserva sus propias
instancias.

Con `data`, un loop que suma `Meters` reserva una caja en cada paso. Cincuenta millones de sumas
tardan 0,36 s y usan 10 MB con `data`, y 0,02 s y 3,7 MB con `newtype`. Un `StateT` declarado con
`newtype` se compila a clausuras comunes.

Un newtype sigue siendo un tipo de Go sólo si se contiene a sí mismo
(`newtype Fix f = Fix (f (Fix f))`), o si se le pasa sin todos sus argumentos a un tipo de datos
que toma un constructor de tipos.

## Sinónimos, comprensiones, deriving

```haskell
type Pair a = (a, a)

[(a, b) | a <- [1 .. 4], b <- ['x', 'y'], odd a]
[n * n | Just n <- maybes]                  -- los elementos que no matchean se saltean
take 5 [n | n <- [1 ..], let sq = n * n, sq `mod` 3 == 1]

data Tree a = Leaf | Node (Tree a) a (Tree a)
  deriving (Show, Functor, Foldable, Traversable)
```

- **Los sinónimos con `type`** toman parámetros y se pueden exportar. Hay que darles todos sus
  argumentos, y un sinónimo que se refiere a sí mismo es un error.
- **Las listas por comprensión** tienen generadores, guardas y `let`, y son perezosas, como las
  listas que construyen.
- **`deriving`** cubre `Eq`, `Ord`, `Show`, `Read`, `Enum`, `Bounded`, `Functor`, `Foldable` y
  `Traversable`. `Enum` pide constructores sin campos; `[minBound .. maxBound]` lista todos los
  valores de un tipo así. Los tres últimos mapean sobre el último parámetro de tipo. `Show` muestra los records con sus campos,
  como Haskell.

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
| `nfib 40 :: Int -> Int`, Hago | 0,34 s | — |
| `nfib 40 :: (Ord a, Num a) => a -> a`, Hago, en `Int` | 0,35 s | — |
| suma de los cuadrados de los múltiplos de 3 hasta 3.000.000, con listas perezosas | 0,45 s | ~10 MB |
| `mapM_` sobre un millón de elementos en IO | 0,19 s | ~8 MB |
| un loop recursivo en IO de cinco millones de iteraciones | 0,31 s | ~8 MB |
| `mapM_` sobre un millón de elementos en `StateT Int IO` | 0,25 s | ~8 MB |
| cincuenta millones de sumas de un `newtype Meters = Meters Double` | 0,02 s | ~4 MB |
| lo mismo con `data Meters = Meters Double` | 0,36 s | ~10 MB |

- **El código estricto en tipos concretos** se compila al Go que escribirías a mano, y rinde
  igual.
- **El código con restricciones o polimórfico sobre constructores** (`Num a =>`, `Monad m =>`)
  no cuesta nada extra, porque se especializa. El precio es el tamaño del código: una copia por
  cada tipo con que se usa.
- **La cadena de listas perezosas** corre en memoria constante, pero cada celda reserva un
  thunk, así que es mucho más lenta que un loop de Go.

## Uso

Hace falta GHC (probado con 9.12) con cabal, y Go 1.21 o posterior.

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compilar y correr
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # sólo compilar
./check.sh                                                  # todos los ejemplos y los rechazados
```

En `examples/` hay listas perezosas, ADTs con pattern matching y guardas, type classes, mónadas
(State, Maybe, Either, listas, reader, writer, Traversable), transformadores de mónadas, módulos,
records, newtypes, tuplas, rangos, listas por comprensión, llamadas a Go y loops.
Cada ejemplo tiene un `.out` con la salida esperada. En `rejected/` hay programas que el type
checker tiene que rechazar, cada uno con el error que espera.

Un error dice dónde está, cita la línea y marca el lugar:

```
rejected/mismatch.hgo:3:18: in main: type mismatch: expected String, got Int
  |
3 | main = putStrLn (length [1, 2, 3])
  |                  ^^^^^^
```

## Qué hay y qué no

Es un prototipo. El pipeline completo funciona de punta a punta: regla de layout, parser,
inferencia Hindley-Milner que elabora a un core tipado, y generación de Go. Pero falta mucho de
Haskell 98.

**Soportado**
- `data` con campos perezosos (`~`) y `deriving`, records, `newtype`, sinónimos con `type`,
  listas por comprensión, firmas de tipos con contextos, funciones con
  varias cláusulas, guardas, `where`, `let`, `case`, `if`, lambdas, `do` en cualquier mónada,
  as-patterns, bindings con patrón (`let (q, r) = ...`), anotaciones `e :: t`, literales con
  exponente.
- `class` con superclases, métodos por defecto y métodos con restricciones, `instance` con
  contextos, clases sobre tipos y sobre constructores de tipos. `Int`, `Double`, `Char`,
  `String`, `Bool`.
- Operadores con declaraciones `infixl`/`infixr`/`infix`, secciones, backquotes, tuplas de hasta
  quince elementos (lo que pide Haskell 98; para más, un record), listas literales, y rangos (`[a ..]`, `[a, b ..]`, `[a .. c]`, `[a, b .. c]`) sobre cualquier `Enum`.
- Polimorfismo de let en el nivel superior, con análisis de dependencias de las definiciones sin
  firma.
- `foreign import go`.

**Falta**
- **La recursión polimórfica a través de una restricción** (una función que se llama a sí misma
  en un tipo más grande) no se puede especializar, y se rechaza.
- **`String` es el `string` de Go, no `[Char]`.** Se convierte con `pack` y `unpack`.
- **Los módulos se compilan junto con el programa,** sin compilación separada ni gestor de
  paquetes.
- **Los loops largos en mónadas puras como `State` consumen pila,** porque su `>>=` es una
  cadena de llamadas de Go. Esos loops se escriben con `tailRecM`. En IO y en transformadores
  sobre IO no consumen pila.
- **No hay clases de varios parámetros,** así que no hay `MonadState s m` al estilo mtl: los
  transformadores se usan con `lift` explícito.
- **Las definiciones locales son monomórficas.** Las funciones literales de Go no pueden ser
  genéricas.
- **Los valores polimórficos del nivel superior no se comparten.** `xs = []` se vuelve una
  función genérica y se reevalúa en cada uso.
- **`Lazy` es un tipo de verdad.** La pereza sólo llega hasta donde la llevan los tipos. Por
  ejemplo, `foldr` toma `a -> Lazy b -> b` para poder cortar antes, y `++` y `<>` suspenden su
  segundo argumento. La adaptación automática cubre el caso de pasar funciones estrictas, pero
  igual puede aparecer un error de tipos que mencione `Lazy` (`liftA2 (:)` es uno; una lambda lo
  resuelve).

## Organización del código

| Archivo | Qué hace |
|---|---|
| `src/Hago/Lexer.hs` | tokens y regla de layout |
| `src/Hago/Parser.hs` | Parsec sobre tokens, resolución de fixity |
| `src/Hago/Rename.hs` | módulos: importaciones, exportaciones y alcances, a un programa plano |
| `src/Hago/Expand.hs` | sinónimos con `type`, que se expanden y desaparecen |
| `src/Hago/Derive.hs` | `deriving (Eq, Ord, Show, Read, Enum, Bounded, Functor, Foldable, Traversable)` |
| `src/Hago/TcMonad.hs` | unificación y el solver de restricciones (instancias, defaulting) |
| `src/Hago/Typecheck.hs` | inferencia y elaboración, donde se insertan `Lazy` y los diccionarios |
| `src/Hago/Core.hs` | el core tipado |
| `src/Hago/Specialize.hs` | copias del código sobre constructores de tipos; los métodos de instancia pasan a ser funciones |
| `src/Hago/Newtype.hs` | los newtypes, reemplazados por el tipo que envuelven |
| `src/Hago/CodeGen.hs` | generación de Go |
| `runtime/runtime.go` | listas, thunks e IO con trampolín; se copia en cada programa |
| `prelude/Prelude.hgo` | el prelude, escrito en Hago |

## Licencia

MIT. Ver [LICENSE](LICENSE).
