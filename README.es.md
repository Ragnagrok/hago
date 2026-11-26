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
  donde se espera una con parámetros `Lazy` (`foldr insert Leaf xs`) se adapta sola. Y al revés:
  una variable de tipo nunca vale `Lazy t`, así que una función con parámetros `Lazy` pasada
  donde se espera una función común (`liftA2 (:)`, `map (False &&)`) recibe ahí argumentos
  comunes. `f $ x` es `f x`, así que `x` sigue siendo perezoso si `f` lo pide.

Las suspensiones son thunks memoizados: se evalúan como mucho una vez. Un programa que corre en
una sola goroutine recibe thunks que no toman ningún lock. Uno que lanza goroutines (ver
[Concurrencia](#concurrencia)) recibe thunks que cualquier goroutine puede forzar: el primero que
llega calcula el valor con el lock del thunk tomado, y una vez calculado, forzarlo es una lectura
atómica. El benchmark de listas perezosas de más abajo corre un 2% más lento con ellos.

Los valores de nivel superior se calculan al arrancar el programa, en orden. Los que se necesitan
entre sí para calcularse (`x = y + 1`, `y = x + 1`) no se pueden calcular, y se rechazan. Los que
son funciones sí pueden referirse entre sí, como hacen los parsers armados con combinadores: cada
uno empieza siendo una función que calcula el valor la primera vez que se la llama.

Las ligaduras locales, de un `let` o un `where`, se calculan donde hacen falta: una que sólo usan
algunas ramas (de un `if`, un `case` o unas guardas) se calcula en esas ramas, y una que nada usa
no se calcula. Así, `safeDiv a b | b == 0 = Nothing | otherwise = Just q where q = a `div` b`
no divide por cero, como pasaría si `q` se calculara antes de las guardas. El código es puro, así
que calcular una ligadura en menos caminos sólo puede evitar fallas, nunca cambiar un resultado.
Lo que usa una guarda, una condición o lo que se analiza en un `case` se calcula antes, y lo que
usa sólo una guarda posterior, después de que fallan las anteriores (salvo que una guarda
anterior necesite alguna de las mismas ligaduras, que entonces se calcularían dos veces).

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
  `examples/transformers.hgo` define `StateT`, `ExceptT`, `MonadTrans`, `MonadIO`, `MonadState`
  y `MonadError`, y corre una misma máquina de pila sobre `StateT [Int] (ExceptT String IO)` y
  sobre `ExceptT String (StateT [Int] IO)`.
- **Las clases pueden tener varios parámetros, con una dependencia funcional** de uno de ellos
  a los demás, como en mtl: `class Monad m => MonadState s m | m -> s`. La mónada elige la
  instancia y fija el tipo del estado, así que con `MonadState Int m`, `n <- get` hace que `n`
  sea un `Int`. Las instancias que pasan las operaciones a través de otros transformadores
  (`MonadState s m => MonadState s (ExceptT e m)`) hacen que `get`, `put` y `throwError` anden
  en cualquier lugar de la pila sin `lift`, y que una función pida sólo lo que usa:
  `pop :: (MonadState [Int] m, MonadError String m) => m Int`. Cada pila con la que se usa tiene
  su propia copia, así que no cuesta nada en tiempo de ejecución.
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
- **Un valor polimórfico también es una plantilla,** así que se calcula una vez por tipo.
  `table :: Num a => [a]` usada en `Int` y en `Double` se vuelve dos variables de Go, cada una
  calculada una vez, como pasaría con un valor monomórfico. Sólo un uso dentro de una función
  genérica, en la variable de tipo de esa función, lo recalcula, porque Go no tiene variables
  genéricas.

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
- **El pattern matching cubre todos los valores,** o el programa se rechaza: las cláusulas de
  una función, un `case`, los patrones de una lambda, `let Just x = ...` y `Just x <- ...` en un
  `do`. El error muestra un valor que nada cubre (`nothing matches Nothing`, `nothing matches 0`).
  Las guardas cuentan cuando una es `otherwise` (o `True`), o cuando se complementan: una
  condición y su `not`, `even` y `odd` del mismo número, o comparaciones de los mismos dos
  valores que entre todas cubren menor, igual y mayor (`n > 0`, `n < 0`, `n == 0`) en `Int`,
  `Integer`, `Char`, `String` o `Bool`. No en `Double`, donde `n < 0` y `n >= 0` son falsas
  las dos para NaN, ni en un tipo cuyo `Ord` escribió alguien, que puede no cumplir las leyes.
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
Go no elimina llamadas de cola. Hago lo resuelve de tres maneras, siguiendo a PureScript y a
Cats de Scala:

- **IO usa un trampolín.** Ejecutar una acción devuelve su resultado o la acción siguiente, y el
  runtime itera sobre ellas. Un bloque `do` que termina en otra acción, `>>=` y `*>` no consumen
  pila: `loop n = do { ...; loop (n + 1) }` corre para siempre, y `mapM_` sobre un millón de
  elementos corre en memoria constante, en IO y en transformadores sobre IO como
  `StateT s IO`. Una acción que se ejecuta apenas se crea (una sentencia de un bloque `do`, o lo
  que devuelve una función cuando se ejecuta la acción de su llamada) no llega a crearse: una
  función que devuelve una acción tiene además una función de Go que hace lo que haría la
  acción, y su llamada a sí misma al final es un loop `for`, también a través de `when` o de un
  `if`. Las funciones que terminan llamándose entre sí son un solo loop `for` sobre cuál de
  ellas está corriendo, y `main` ejecuta su cuerpo en vez de armar su acción, así que
  `main = loop 0` es ese loop. Una llamada al final a una acción recibida como argumento sigue
  pasando por el trampolín, y no hace crecer la pila (`examples/io-loops.hgo`).
- **`Identity` también,** la mónada pura de la biblioteca, y con ella todo transformador encima:
  el `State s` de la biblioteca es `StateT s Identity`, igual que `Reader` y `Except`. Diez
  millones de pasos de `loop n = do { modify (+ n); loop (n - 1) }` corren en 10 MB, y un millón
  corre más rápido que en una mónada `s -> (a, s)` escrita a mano, que suma un marco a la pila de
  Go por paso y muere cerca de los diez millones, en el límite de 1 GB de Go.
- **`MonadRec` y `tailRecM`** corren loops con pila constante en una mónada propia. `IO`,
  `Maybe`, `Either e` y los transformadores de la biblioteca tienen instancia, se puede escribir
  una (ver `examples/monads.hgo`), y `forever` está construido encima.

## Módulos

```haskell
module Data.Stack (Stack, empty, push, pop) where   -- Stack es abstracto

import qualified Data.Stack as S
import Geometry.Shapes (Shape(..), area)
import Geometry.Shapes hiding (perimeter)

module Geometry (module Geometry.Shapes, scale) where   -- reexporta Geometry.Shapes
```

- **Un módulo `A.B` vive en `A/B.hgo`,** junto al archivo principal, que es `Main`, o en la
  biblioteca estándar.
- **Las listas de exportación e importación, `qualified`, `as` y `hiding`** funcionan como en
  Haskell. Un tipo exportado sin `(..)` es abstracto.
- **Un módulo puede reexportar** lo que importa, nombre por nombre o un módulo entero con
  `module M`. Dos cosas distintas con el mismo nombre en una lista de exportación son un error.
- **Las definiciones propias tapan a las importadas,** así que un módulo puede definir su propio
  `toList`. Dos importaciones que le dan significados distintos a un mismo nombre son ambiguas
  sólo donde ese nombre se usa.
- **Las instancias son globales,** como en Haskell.

### La biblioteca estándar

Algunos módulos vienen con el compilador, y un programa los importa como a los suyos (un módulo
del programa con el mismo nombre tiene prioridad). [La referencia de la
biblioteca](docs/library/README.md) (en inglés) tiene cada nombre que exporta cada uno, con su
tipo y lo que hace:

| Módulo | Qué tiene |
| --- | --- |
| `Control.Monad` | `foldM`, `replicateM`, `filterM`, `zipWithM`, `>=>`, `liftM2`, `ap`, `void`, y `when`, `unless`, `forM_`... del Prelude |
| `Control.Monad.State` | `StateT`, `State`, `MonadState` (`get`, `put`), `modify`, `gets`, `runState`, `evalState`, `execState` |
| `Control.Monad.Reader` | `ReaderT`, `Reader`, `MonadReader` (`ask`, `local`), `asks` |
| `Control.Monad.Except` | `ExceptT`, `Except`, `MonadError` (`throwError`, `catchError`), `liftEither` |
| `Control.Monad.Writer` | `WriterT`, `Writer`, `MonadWriter` (`tell`), `runWriter`, `execWriter` |
| `Control.Monad.Trans` | `MonadTrans` (`lift`), `MonadIO` (`liftIO`) |
| `Data.Functor.Identity` | `Identity`, con trampolín |
| `Data.String` | `uncons` en tiempo constante (un string de Go se recorta, no se copia), `length`, `elem`, `isPrefixOf`, `stripPrefix`, `stripSuffix`, `span`, `break`, `takeWhile` y `dropWhile` (recortes, en una pasada), `concat` en una pasada, `intercalate`, `replicate`; se importa calificado |
| `Data.List` | `sort` (un merge sort estable), `sortBy`, `sortOn`, `nub`, `group`, `partition`, `intercalate` (de cualquier `Monoid`, así que también de `String`s), `intersperse`, `transpose`, `isPrefixOf` y parecidas, `tails`, `inits`, `subsequences`, `permutations`, `delete`, `\\`, `union`, `intersect`, `elemIndex`, `findIndex`, `unfoldr`, `maximumBy` y `minimumBy` (con `Maybe`) |
| `Data.Char` | `toUpper`, `toLower`, las pruebas de Unicode (`isPunctuation`, `isSymbol`...), `digitToInt` e `intToDigit` (con `Maybe`) |
| `Control.Applicative` | `ZipList`, `liftA3`, `optional` (`Applicative` y `Alternative` están en el Prelude) |
| `Data.Monoid` | `First`, `Last`, `Min`, `Max`, y `Sum`, `Product`, `Any`, `All` del Prelude |
| `Data.Ord` | `comparing`, `Down`, `clamp` |
| `Data.Map` | árboles de búsqueda balanceados de claves a valores, como en containers: `fromList`, `fromListWith`, `insert`, `insertWith`, `lookup`, `!?` (sin `!`), `adjust`, `alter`, `delete`, `unionWith`, folds, `Functor` y `Foldable`; conviene importarlo calificado |
| `Data.Set` | lo mismo para conjuntos: `member`, `union`, `intersection`, `difference`, `isSubsetOf`; conviene importarlo calificado |
| `Data.Vector` | `Vector a`, un slice de Go que Hago nunca modifica: `fromList`, `!?`, `generate`, `map`, `imap`, `filter`, `foldl`, `slice` (sin copiar), `sort`, `sortOn`, `zipWith`, `Foldable`; se importa calificado |
| `Data.Iter` | `Iter a`, el `iter.Seq` de Go: `from`, `range`, `iterate`, `lines`, `words`, `map`, `filter`, `takeWhile`, `take`, `zipWith`, `foldl`, `sum`, `find`, `mapM_`, `singleton`; es `Monad` y `Monoid`; se importa calificado |
| `Data.Ratio` | `Rational` (el `*big.Rat` de Go), exacto: `%`, `numerator`, `denominator`, `Num`, `Fractional`, `fromRational`, `toRational` |
| `Data.String.Builder` | `Builder`, un `Monoid` de pedazos que `toString` une en una pasada, para textos largos armados de muchos pedazos |
| `Text.Regex` | el `regexp` de Go (RE2, tiempo lineal): `compile`, `matches`, `find`, `findAll`, `groups`, `replaceAll` (con `$1`), `replaceAllWith`, `split`; se importa calificado |
| `Data.Time` | el `time.Time` de Go: `getCurrentTime`, `diffSeconds`, `addSeconds`, `format` y `parse` con los layouts de Go, `year`, `month`, `day`... |
| `Crypto.Hash`, `Data.Encoding` | `sha1`, `sha256`, `sha512` en hexadecimal; `base64Encode`, `base64Decode`, `hexEncode`, `hexDecode` |
| `System.Process` | `readProcess`: corre un programa con argumentos y entrada, y da su salida |
| `Network.HTTP` | `get` y `post` con el `net/http` de Go, que dan un `Response` con su `status` y su `body` |
| `System.Environment` | `getArgs`, `getProgName` |
| `System.IO` | `stdin`, `stdout`, `stderr`, `hPutStrLn`, `hPrint`, `isEOF`, y el resto de los nombres de Haskell para los tres handles estándar |
| `System.Exit` | `exitWith`, `exitSuccess`, `exitFailure` |
| `System.Random` | `StdGen` (SplitMix64), `mkStdGen`, `randomR`, `random`, `randomRs`, `randoms`, `split`; en IO `newStdGen` y `randomRIO`, con semilla del reloj o de `HAGO_RANDOM_SEED` |
| `Control.Concurrent` | `forkIO`, `threadDelay`, `yield`, `getNumCapabilities`; `MVar` con `takeMVar`, `putMVar`, `readMVar`, las versiones `try`, `modifyMVar_`, `modifyMVar`, `withMVar` |
| `Control.Concurrent.Channel` | los canales de Go: `newChannel` (con el tamaño de su buffer), `send`, `receive` (`Nothing` una vez cerrado), `close`, `receiveAll`, y `select` sobre `onReceive`, `onSend` y `after` |
| `Control.Concurrent.Async` | `async`, `wait`, `poll`, `concurrently`, `race`, `mapConcurrently`, `forConcurrently` y sus versiones con `_` |
| `Control.Parallel` | `parMap`: `map` con los elementos calculados en todos los procesadores |
| `Data.IORef` | `IORef`, una referencia que los hilos pueden compartir: `newIORef`, `readIORef`, `writeIORef`, `modifyIORef'` y `atomicModifyIORef'` (atómicas) |
| `Control.Monad.ST`, `Data.STRef` | `ST s`, `runST` (pura), `STRef` con `newSTRef`, `readSTRef`, `writeSTRef`, `modifySTRef'`; `PrimMonad`, la clase de IO y de `ST s` |
| `Data.Vector.Mutable` | `MVector s a` (`IOVector a`, `STVector s a`), un slice de Go que se modifica en el lugar: `replicate`, `generate`, `read`, `readMaybe`, `write`, `modify`, `swap`, `set`, `length`, `freeze` y `thaw` (copiando a y desde un `Vector`); se importa calificado |
| `Data.HashTable` | `HashTable s k v` (`IOHashTable k v`), un map de Go: `new`, `fromList`, `insert`, `insertWith`, `alter`, `lookup` (con `Maybe`), `member`, `delete`, `size`, `toList`; las claves son los tipos que Go compara por valor (`Key`); se importa calificado |

El Prelude lee y escribe archivos y la entrada estándar: `getContents` e `interact` (que leen
toda la entrada primero), y `readFile`, `writeFile` y `appendFile`, que devuelven un
`Either String` porque pueden fallar. `getLine` da `""` al final de la entrada, que
`System.IO.isEOF` distingue de una línea vacía.

Cada clase pasa a través de los otros transformadores, como en mtl, así que una función puede
pedir `(MonadReader Config m, MonadState Int m, MonadError String m)` y correr sobre cualquier
pila que los tenga. `examples/mtl.hgo` los usa a todos.

Un paso de renombrado resuelve cada nombre a uno interno, calificado por su módulo
(`Geometry.Shapes.area`), así que los módulos nunca chocan una vez compilados.

### Compilación separada

Cada módulo se renombra y se chequea por su cuenta, con lo que le dan sus importaciones
(directamente o a través de otras importaciones) y nada más, que es también lo que decide qué
instancias ve. Lo que un módulo les da a los que vienen después (sus nombres, sinónimos,
fixities, y sus declaraciones chequeadas con todos los tipos resueltos) se guarda en una caché,
bajo una clave hecha del compilador, la fuente del módulo y las claves de sus importaciones. La
compilación siguiente lo reusa mientras esa clave no cambie: el Prelude y la biblioteca se
chequean una vez, y también cada módulo que no se tocó y cuyas importaciones no cambiaron.

La especialización y la generación de Go siguen viendo el programa entero, como la
monomorfización en Rust: una plantilla se copia para los tipos con que cada programa la usa.
Arrancan desde `main` y sólo emiten lo que alcanza, así que un programa que imprime un número son
5 KB de Go, no el Prelude entero.

La caché vive en `~/.cache/hago`; `HAGO_CACHE=dir` la mueve y `HAGO_CACHE=off` la apaga.
Compilar un ejemplo tarda unos 0,35 s la primera vez y de 0,15 s a 0,25 s las siguientes, más
`go build`.

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
  listas que construyen. Un generador es un `foldr` que pone cada elemento antes del resto o lo
  saltea, como las traduce GHC, así que una comprensión guardada como lista es un loop que
  saltea lo que las guardas descartan y arma una celda por elemento cuando se llega a él.
- **`deriving`** cubre `Eq`, `Ord`, `Show`, `Read`, `Enum`, `Bounded`, `Functor`, `Foldable` y
  `Traversable`. `Enum` pide constructores sin campos; `[minBound .. maxBound]` lista todos los
  valores de un tipo así. Los tres últimos mapean sobre el último parámetro de tipo. `Show` muestra los records con sus campos,
  como Haskell.

## Cómo queda el Go

`map` se compila a una función genérica de Go. Una lista es un puntero a su primera celda, `nil`
si está vacía, y un valor `Lazy` es un puntero a un thunk. Una celda y el thunk de su cola son
una sola reserva de memoria (la clausura que calcula la cola es otra):

```go
func map_[T_a any, T_b any](_arg0 func(T_a) T_b, _arg1 List[T_a]) List[T_b] {
	...
		if _arg1 != nil {
			x := _arg1.F0
			xs := _arg1.F1
			return func() List[T_b] {
				hg_c := &struct {
					c  Cons[T_b]
					t1 rt_thunk[List[T_b]]
				}{c: Cons[T_b]{F0: g(x)}, t1: rt_thunk[List[T_b]]{f: func() List[T_b] {
					return map_[T_a, T_b](g, xs.force())
				}}}
				hg_c.c.F1 = &hg_c.t1
				return &hg_c.c
			}()
		}
	...
}
```

- **Los tipos de datos** se guardan de la forma más barata que su forma permite. Uno con un solo
  constructor es el struct de ese constructor, pasado por valor, así que
  `data Meters = Meters Double` cuesta lo mismo que un `newtype`; si es demasiado grande para
  eso (más de ocho palabras) o se contiene a sí mismo, un puntero al struct, cuyos campos se
  leen a través de él. Un tipo suma chico que no se
  contiene a sí mismo (`Maybe`, `Either`, `Ordering`) es un struct con una etiqueta, también
  por valor. Uno con dos constructores, uno sin campos (una lista, los árboles de `Data.Map`),
  es un puntero, `nil` para el vacío. Cualquier otro es una interfaz de Go con un struct por
  constructor. Un campo de un tipo que se contiene a sí mismo cuenta como el puntero o la
  interfaz que es, así que un record con un `Map` adentro se sigue guardando por valor.

- **El polimorfismo** se traduce a genéricos de Go.
- **Las llamadas** a funciones conocidas son llamadas directas de Go. La aplicación parcial y las
  funciones como valores usan closures currificadas.
- **Las llamadas de cola a sí misma** se vuelven un `for`, así que `filter` saltea elementos y
  los loops con acumulador corren con pila constante. Las funciones que terminan llamándose entre
  sí en círculo (una máquina de estados, `isEven` e `isOdd`) son un solo loop `for` sobre cuál de
  ellas está corriendo, en el nivel superior o locales (`examples/loops.hgo`).

## Llamar a Go

```haskell
foreign import go "strings.Repeat" repeatString :: String -> Int -> String
foreign import go "strconv.Atoi"   parseInt     :: String -> Either String Int
foreign import go "fmt.Println"    goPrintln    :: String -> IO ()
foreign import go "math.MaxInt32"  maxInt32     :: Int
```

- `Int`, `Bool`, `Char` y `String` son `int`, `bool`, `rune` y `string` de Go, así que los
  valores cruzan la frontera sin conversión. `Integer` es un `*big.Int` que nunca se modifica.
- Una función de Go que devuelve `(T, error)` se declara como `Either String T`, o
  `IO (Either String T)` si tiene efectos. Una que devuelve sólo un `error` es un
  `Either String ()`.
- `IO ()` significa que se la llama por sus efectos y se ignoran sus resultados.
- El paquete se importa desde la ruta anterior al último punto: `"path/filepath.Join"` importa
  `path/filepath`.
- Declarar una función sin `IO` es una promesa tuya de que es pura.
- Una polimórfica es una función genérica de Go, cuyos parámetros de tipo son las variables de
  tipo de Hago en el orden en que aparecen por primera vez en la firma.

Un tipo de Go que el código de Hago sólo pasa de un lado a otro se declara con
`foreign import go type`:

```haskell
foreign import go type "*net/url.URL" URL
foreign import go "net/url.Parse" parseURL :: String -> Either String URL
foreign import go type "*rt_MVar" MVar a       -- el del runtime, genérico: *rt_MVar[T]
```

No tiene constructores, así que el código de Hago no puede mirar adentro ni armar uno; eso lo
hacen funciones de Go, y sus campos y métodos. Un símbolo que empieza con un punto es un selector
sobre el primer argumento, seguido de los demás argumentos si los hay:

```haskell
foreign import go ".Scheme"          scheme     :: URL -> String            -- u.Scheme
foreign import go ".Hostname()"      hostname   :: URL -> String            -- u.Hostname()
foreign import go ".Query().Get"     queryParam :: URL -> String -> String  -- u.Query().Get(k)
```

Una función o acción de Hago que se le pasa a una función de Go se convierte en la función de Go
que espera, que toma todos sus argumentos juntos y ejecuta la acción que arma:

```haskell
foreign import go "strings.Map" mapRunes :: (Char -> Char) -> String -> String
foreign import go ".HandleFunc" handleFunc
  :: ServeMux -> String -> (ResponseWriter -> Request -> IO ()) -> IO ()
```

Go la puede llamar desde cualquier goroutine, así que un programa que le pasa una función a Go
recibe el runtime concurrente (ver [Concurrencia](#concurrencia)). `examples/http-server.hgo`
sirve páginas con `net/http` y se pide varias a sí mismo a la vez.

## Listas, iteradores y vectores

Hago tiene tres clases de secuencia, cada una para lo suyo:

| | `[a]` | `Iter a` (`Data.Iter`) | `Vector a` (`Data.Vector`) |
|---|---|---|---|
| Qué es | celdas con cola perezosa | el `iter.Seq` de Go | un slice de Go |
| Patrones (`x : xs`) y recursión | sí | no | no |
| Agregar adelante compartiendo el resto | O(1) | no | copia |
| Consumida dos veces | se calcula una vez y se comparte | se calcula dos veces | guardada |
| Infinita | sí | sí | no |
| Un pipeline sobre millones de valores | una allocation por celda, ninguna si se pliega donde se arma | ninguna allocation por valor | los guarda todos |
| Llegar al n-ésimo elemento | O(n) | O(n) | O(1) |

- **Una lista es una estructura de datos:** para recursión y patrones, para armar un resultado de
  a un elemento, y para valores que comparten partes (un zipper, una pila). Su cola es perezosa,
  así que puede ser infinita, y lo que ya se calculó queda para el próximo que la lea.
- **Un `Iter` es un cálculo:** un pipeline de `map`, `filter` y `takeWhile` sobre algo grande o
  sin fin, que se consume una vez. No se puede desarmar con un patrón porque no tiene un "resto"
  que dar: un `uncons` tendría que volver a correrlo desde el principio, o guardar lo calculado,
  que es lo que hace una lista.
- **Un `Vector` son datos ya calculados,** a los que se llega por posición, y el tipo que dan y
  reciben las funciones de Go para slices:
  `foreign import go "strings.Split" split :: String -> String -> Vector String`.

**Una lista que se arma sólo para plegarla nunca se arma.** Cuando `sum`, `length`, `foldl`,
`maximum`, `any`, `all`, `elem`, `find`, `and`, `or`, `mapM_`, `forM_` o `traverse_` reciben
una lista construida ahí mismo con rangos, `map`, `filter`, `take`, `takeWhile`, `repeat`,
`iterate`, `replicate`, `++`, `concatMap`, `if`, `let` y literales, o una comprensión hecha de
ellos, el compilador genera los loops de Go que recorren sus elementos, anidados para una
comprensión, y no reserva ninguna celda: `length [(a, b, c) | c <- [1 .. 400], b <- [1 .. c],
a <- [1 .. b], a * a + b * b == c * c]` son tres loops `for`. Se calcula lo que tendría la
lista, en el mismo orden: cada elemento (la cabeza de una celda es estricta, así que
`length (map f xs)` igual calcula cada `f x`), y nada más de lo que pide el pliegue
(`take 5 (iterate f x)` llama a `f` cuatro veces, `any p [1 ..]` se detiene). `zip` y
`zipWith` también son loops: una lista se recorre con sus loops y la otra de a un paso, con la
celda de la primera alcanzada antes que la de la segunda, como hace `zip`. También lo es
`mapM_` en una mónada que pasa un estado, como `StateT s IO`: el estado es una variable del
loop. `drop`, `dropWhile`, `zip3`, `zipWith3`, y un `foldr` cuyo paso descarta su resto (la
lista termina ahí) arman listas de la misma manera. Un `foldr` cuyo paso necesita el resto para
calcular su propio valor (`foldr (+) 0 xs`, `foldr max 0 xs`,
``foldr (\x acc -> f x `div` acc) 1 xs``) es recursión, no un loop. Cuando el paso fuerza el
resto fuera de ramas y lambdas, lo que calcula antes del resto se calcula a la ida, con los
elementos, y se guarda con cada uno (lo que no puede fallar se deja para después), y el resto
del paso se toma desde el último elemento hacia atrás: todo en el orden de la recursión, así
que diez millones de elementos no necesitan ni la pila de Go ni una suspensión cada uno. Los
elementos se guardan en bloques que nunca se copian, y no se guardan cuando son un rango: se
recorre desde su final. Una lista en una variable, o pasada a una función, es una lista como
antes (`examples/fusion.hgo`).

Una función que se le pasa a una función de Go, como hacen `map`, `filter` y `foldl`, se genera
como una función de Go de todos sus argumentos, así que un pipeline sobre un `Iter` corre como el
loop de Go que representa (ver [Performance](#performance)).

`Iter` es una `Monad`, un `Alternative` y un `Monoid`, como las listas, así que un `do` sobre
iteradores es una comprensión que no arma ninguna lista:

```haskell
triples :: Int -> Iter (Int, Int, Int)
triples n = do
  c <- Iter.range 1 n
  b <- Iter.range 1 c
  a <- Iter.range 1 b
  guard (a * a + b * b == c * c)
  pure (a, b, c)
```

Es un valor que se puede pasar y consumir después. Un `do` hecho con las funciones de
`Data.Iter`, como este, se compila a una sola función de Go con los tres loops, que le da cada
terna a quien la consume y no reserva nada por valor; un pliegue (`length`, `sum`, `foldl`, `find`, `any`,
`all`, `elem`) o un `mapM_` de un `Iter` armado donde se consume es los loops mismos. Las comprensiones y los
rangos (`[x | x <- xs]`, `[1 ..]`) son siempre listas: hacerlos `Iter` cuando el tipo lo pide
volvería su tipo una elección que la mayoría de los usos (`length`, `sum`, `mapM_`) deja abierta.

## Concurrencia

Un hilo de Hago es una goroutine: lanzar uno es barato, y pueden correr miles a la vez.

```haskell
import Control.Concurrent
import Control.Concurrent.Async

main = do
  counter <- newMVar 0
  mapConcurrently (\_ -> modifyMVar_ counter (pure . (+ 1))) [1 .. 1000]
  readMVar counter >>= print                       -- 1000
  race (threadDelay 100000) (pure "fast") >>= print  -- Right "fast"
```

- **Las MVar** (`Control.Concurrent`) son cajas vacías o con un valor: `takeMVar` espera a que
  haya uno, `putMVar` a que haya lugar. **Los canales** (`Control.Concurrent.Channel`) son los de
  Go, con buffer, `close` y `select`. **`Control.Concurrent.Async`** corre acciones a la vez y
  espera sus resultados sin manejar hilos. **`parMap`** (`Control.Parallel`) es un `map` puro
  calculado en todos los procesadores, con el mismo resultado que `map`.
- **Los valores son inmutables, así que los hilos los comparten sin cuidado.** El único estado
  que comparten y cambian está en MVars y canales. También se puede compartir una lista perezosa:
  sus celdas se calculan una vez, en el hilo que las fuerce primero. `check.sh` corre los ejemplos
  bajo el detector de carreras de Go.
- **Una falla en cualquier hilo termina el programa,** con `error:` y el motivo, como en el
  principal. Hago no tiene excepciones que atrapar, así que no hay nada que entregarle al hilo
  que espera.
- **Go no puede frenar una goroutine desde afuera,** así que no hay `killThread`, y `race` no
  cancela la acción que pierde: corre hasta el final y su resultado se descarta. A un hilo que
  tiene que terminar antes hay que avisarle, con una MVar o un canal.
- **Cuando todos los hilos esperan a otro,** Go frena el programa con `fatal error: all goroutines
  are asleep - deadlock!`. Go agregaría la traza de cada goroutine, salvo que `GOTRACEBACK=none`
  esté puesta al arrancar, así que un programa que usa concurrencia se vuelve a lanzar con ella.
- **Sólo pagan los programas que usan concurrencia.** Un programa recibe el runtime concurrente
  cuando llama a una función de estos módulos, o a una función de Go que recibe una función o
  acción de Hago, que Go podría llamar desde otra goroutine.

## Estado mutable

```haskell
import Control.Monad.ST
import Data.STRef
import Data.IORef

sumST :: [Int] -> Int           -- una función pura que muta por dentro
sumST xs = runST $ do
  total <- newSTRef 0
  mapM_ (\x -> modifySTRef' total (+ x)) xs
  readSTRef total

main = do
  counter <- newIORef 0
  mapM_ (\x -> modifyIORef' counter (+ x)) [1 .. 10]
  readIORef counter >>= print   -- 55
  print (sumST [1 .. 10])       -- 55
```

- **La mayor parte del código no lo necesita:** un fold, un `Data.Map` o la mónada `State` dicen
  lo mismo sin cambiar nada. Mutar conviene cuando el algoritmo está escrito en esos términos,
  y llega a los elementos y los cambia por posición o por clave: una criba, una tabla de
  programación dinámica, el conjunto de visitados de una búsqueda en un grafo, cuentas en
  casilleros. `examples/sieve.hgo` es de 6 a 10 veces más rápido sobre un vector mutable que con
  un `Data.Map`, y `examples/frequencies.hgo` 3 veces más rápido sobre una tabla de hash (ver
  [Performance](#performance)).
- **En IO:** `Data.IORef`, `Data.Vector.Mutable` (`IOVector a`) y `Data.HashTable`
  (`IOHashTable k v`).
- **En ST, puro desde afuera.** Un `ST s a` es un cálculo sobre estructuras propias, de estado
  `s`: `STRef s a`, `STVector s a`, `HashTable s k v`. `runST` lo corre y da su resultado, y es
  pura porque nada de lo que se crea adentro se usa afuera. El type checker le da a cada `runST`
  un estado propio, una `s` rígida que no puede aparecer ni en su resultado (`runST (newSTRef 0)`
  se rechaza: la referencia sobreviviría al cálculo) ni en los tipos de las variables de afuera
  que usa (una estructura de un `runST` no puede usarla otro). Los mismos argumentos dan el
  mismo resultado. Haskell escribe el tipo de `runST` como `(forall s. ST s a) -> a`; Hago no
  tiene esos tipos, y chequea `runST` con una regla propia, como hacía GHC, así que hay que
  aplicarla a su argumento (`runST (do ...)`, `runST $ do ...`) en vez de pasarla como función.
- **Las mismas funciones en los dos.** Un vector es un `MVector s a` y una tabla un
  `HashTable s k v`, como en el vector de Haskell (`IOVector = MVector RealWorld`), y sus
  operaciones corren en cualquier `PrimMonad s m`: IO, cuyo estado es `RealWorld`, y `ST s`. Una
  función escrita una vez corre en los dos (`histogram` en `examples/mutable.hgo`). Las
  referencias tienen un tipo cada una, como en Haskell, porque una `IORef` es atómica y una
  `STRef` no necesita serlo. En tiempo de ejecución una acción de ST es una acción de IO (los
  newtypes son gratis), que `runST` corre.
- **Un índice fuera de rango termina el programa,** con `error: index out of range: 10, in a
  vector of length 10`, como en Go. El código puro no tiene funciones parciales, pero acá el
  índice sale del algoritmo: uno fuera de los límites es un error del algoritmo, que ningún
  resultado arreglaría, y un `Maybe` en cada lectura de un loop sólo se miraría para parar. Una
  división por cero termina el programa por la misma razón. `readMaybe` es para un índice que
  viene de afuera. No hay un `new` con elementos todavía indefinidos: `replicate` y `generate`
  le dan su valor a cada uno.
- **Las claves de una tabla de hash son los tipos que Go compara por valor:** `Int`, `Char`,
  `String`, `Bool`, `()` y las tuplas de claves, las instancias de la clase `Key`, que sólo
  `Data.HashTable` puede dar. Un map de Go compara las claves con `==`, que para una lista o un
  árbol, guardados como puntero, es la identidad, y también para un `Integer`; un `Double` puede
  ser NaN, que no es igual a sí mismo. Las demás claves van en un `Data.Map`. Las funciones
  genéricas generadas declaran sus tipos como `any`, y un map de Go necesita `comparable`, así
  que la tabla guarda su map como un `any`: sus operaciones sólo se llaman desde código
  especializado a un tipo de clave, cosa que asegura `Key k`.
- **Hilos.** Una `IORef` es un puntero atómico a su valor, y `modifyIORef'` y
  `atomicModifyIORef'` vuelven a probar si otro hilo escribió en el medio, así que no se pierde
  ningún cambio. Un vector o una tabla creados en IO, en un programa con hilos, tienen un lock
  que toma cada operación, así que ningún hilo ve la mitad de un valor que otro está
  escribiendo, y un map de Go nunca lo escriben dos a la vez: cada operación es atómica
  (`insertWith` y `alter` también), una secuencia de ellas no. Un programa sin hilos, y todo lo
  creado en ST, no tiene lock; tampoco un vector o una tabla que ningún otro hilo puede
  alcanzar: uno que la acción que lo creó sólo les da a las operaciones de su módulo, en sus
  propias sentencias, los pliegues que corren ahí y las funciones que llama que hacen lo mismo
  (el compilador lo revisa, entre funciones; `examples/concurrent-escapes.hgo` tiene las maneras
  en que uno se escapa, bajo el race detector).
- **Cada operación es una llamada a Go.** `read` y `write` son funciones chicas de la
  biblioteca, que se copian en el código que las llama, y una acción que se ejecuta apenas se
  crea no se crea (ver [Loops y la pila](#loops-y-la-pila)), así que un loop sobre un vector, en
  ST o en IO, es un loop de Go. Una lectura o una escritura que se ejecuta en el momento se
  escribe ahí mismo, con el índice revisado y el vector indexado en una sola prueba, y la función
  del runtime sólo para el lock y el error: la criba hasta diez millones tarda 0,03 s, como el
  loop de Go.

## Performance

Son números de una sola máquina (un i7-12700K, Go 1.27, en sus ocho núcleos de rendimiento),
como referencia y no como benchmark: cada uno es la mediana de nueve corridas. Los programas
están en `bench/` (y en `examples/`), y `bench/run.sh` los mide, con el compilador del árbol o
lado a lado con otros (`bench/run.sh HAGO_VIEJO HAGO_NUEVO`).

| Programa | Tiempo | Memoria máxima |
|---|---|---|
| `nfib 40`, Go escrito a mano | 0,35 s | — |
| `nfib 40 :: Int -> Int`, Hago | 0,37 s | — |
| `nfib 40 :: (Ord a, Num a) => a -> a`, Hago, en `Int` | 0,36 s | — |
| suma de los cuadrados de los múltiplos de 3 hasta 3.000.000, con listas perezosas | <0,01 s | ~2 MB |
| lo mismo con `Data.Iter` (`Iter.sum (Iter.map ... (Iter.from 1))`) | <0,01 s | ~2 MB |
| lo mismo sobre un `Data.Vector` de 3.000.000 de elementos | 0,02 s | ~58 MB |
| ternas pitagóricas hasta 400, como comprensión de listas | <0,01 s | ~2 MB |
| lo mismo como `do` sobre `Iter` | <0,01 s | ~2 MB |
| lo mismo con `Iter.filter` para el último generador y la guarda | <0,01 s | ~2 MB |
| `foldr (+) 0 [1 .. 10000000]` | <0,01 s | ~2 MB |
| ``foldr (\x r -> x `mod` 7 + r) 0 [1 .. 10000000]`` (`mod` puede fallar: se guarda, calculado a la ida) | 0,03 s | ~81 MB |
| `mapM_` sobre un millón de elementos en IO | <0,01 s | ~2 MB |
| un loop recursivo en IO de cinco millones de iteraciones | <0,01 s | ~2 MB |
| lo mismo con dos funciones que se llaman entre sí | <0,01 s | ~2 MB |
| dos funciones puras que terminan llamándose entre sí, cien millones de veces | 0,03 s | ~2 MB |
| `mapM_` sobre un millón de elementos en `StateT Int IO` | <0,01 s | ~2 MB |
| cincuenta millones de sumas de un `newtype Meters = Meters Double` | 0,02 s | ~2 MB |
| lo mismo con `data Meters = Meters Double` | 0,02 s | ~2 MB |
| parsear e imprimir con formato 3,7 MB de JSON con `examples/json.hgo` (`jq .`: 0,09 s, 28 MB) | 0,20 s | ~102 MB |
| `fib 32` dieciséis veces con `map` | 0,13 s | — |
| lo mismo con `parMap`, en 16 procesadores | 0,03 s | — |
| un millón de inserciones en un `Data.Map`, después medio millón de borrados con `foldl`, y búsquedas | 0,36 s | ~80 MB |
| lo mismo con un `Data.Set` | 0,34 s | ~81 MB |
| los primos hasta un millón, criba de Eratóstenes sobre un `STVector` (`examples/sieve.hgo`) | <0,01 s | ~3 MB |
| lo mismo con un `Data.Map` (la criba incremental) | 0,37 s | ~35 MB |
| los primos hasta diez millones, sobre un `STVector` | 0,03 s | ~11 MB |
| lo mismo sobre un `IOVector` | 0,03 s | ~11 MB |
| lo mismo sobre un `IOVector`, en un programa con hilos | 0,04 s | ~11 MB |
| lo mismo con un `Data.Map` | 5,2 s | ~120 MB |
| lo mismo, Go escrito a mano | 0,03 s | ~12 MB |
| cuántas veces aparece cada uno de un millón de números, en una `HashTable` en ST (`examples/frequencies.hgo`) | 0,12 s | ~35 MB |
| lo mismo con un `Data.Map` | 0,42 s | ~35 MB |

El JSON es el que escribe `bench/json-input.go`, siempre el mismo:
`go run bench/json-input.go > input.json`, y después `hago run examples/json.hgo input.json`.

- **El código estricto en tipos concretos** se compila al Go que escribirías a mano, y rinde
  igual. La función de `nfib` es la del programa escrito a mano; la diferencia entre los dos es
  dónde la ubica Go, que mueve su tiempo una décima de un build a otro.
- **Las funciones chicas se copian en quien las llama** (`src/Hago/Inline.hs`): los envoltorios
  de la biblioteca (`when`, `unsafePrimIO`, los métodos de las instancias de IO y de ST, el
  `read` de un vector) no dejan ninguna llamada, y con ellos una acción que se ejecuta donde se
  crea no se construye, así que un loop en IO o en ST es un loop de Go (ver
  [Loops y la pila](#loops-y-la-pila)).
- **Las funciones locales que sólo se llaman pasan al nivel superior** (`src/Hago/Lift.hs`),
  con lo que usan de alrededor como parámetros, como hace GHC: un `go` en un `where` no es una
  clausura que se vuelve a crear en cada llamada. Una función que sólo crea funciones locales y
  valores baratos y devuelve una (`eval c s = go`) recibe también el argumento de esa función,
  así su `go` sólo se llama (`examples/lift.hgo`). Era un tercio de lo que reservaba el núcleo
  de Hugen. Y un valor escrito en el código, un constructor aplicado a constantes (una lista de
  constantes, un record de literales), se crea una sola vez, como valor del nivel superior, en
  vez de cada vez que corre el código que lo rodea; una llamada no, aunque sea de constantes,
  porque guardar su resultado durante toda la ejecución podría retener una lista larga.
- **El código con restricciones o polimórfico sobre constructores** (`Num a =>`, `Monad m =>`)
  no cuesta nada extra, porque se especializa. El precio es el tamaño del código: una copia por
  cada tipo con que se usa.
- **Una lista que se pliega donde se arma** (la cadena de cuadrados, la comprensión de ternas,
  `mapM_` sobre un rango) es un loop de Go y no reserva nada (ver
  [Listas, iteradores y vectores](#listas-iteradores-y-vectores)). Una lista guardada en una
  variable y plegada después sí se arma: cada celda reserva su thunk junto con ella, y la
  clausura que calcula el resto; el pliegue es un loop sobre sus celdas. Una celda que se sabe
  la última comparte con todas las demás un solo thunk para su cola vacía, y `[x] ++ ys` es una
  sola celda cuya cola es `ys`.
- **Los combinadores de parsers** piden cuidado. La respuesta de `Text.Parser` a cada paso es un
  solo constructor, lo bastante chico para guardarse por valor (el valor como un `Maybe`, la
  entrada que queda, lo que se esperaba ahí), así que un paso no reserva memoria; si consumió
  entrada es si lo que dejó no es lo que recibió, y la línea y la columna de un error sólo se
  cuentan cuando `parse` devuelve uno. Una tirada de caracteres es un solo paso (`takeWhileP`,
  sobre `Data.String.span`), y lo que un parser consumió es un recorte de la entrada (`match`),
  así que un número nunca se arma con sus pedazos. Eso llevó el benchmark de JSON de 1,86 s a
  0,32 s; casi todo lo que queda son los documentos y las listas del pretty-printer, y el
  recolector de basura de Go.
- **El recolector de basura de Go no es generacional:** cada ciclo marca todo lo que está vivo,
  así que lo que cuesta crece con lo que un programa reserva, y un programa funcional reserva
  mucho y por poco tiempo. Dos cosas lo abaratan. Los programas corren con `GOGC=200` salvo que
  `GOGC` esté definido: el heap llega a tres veces lo que está vivo, como el de GHC por defecto,
  y los ciclos son la mitad (`Data.Map` 1,79 s → 1,44 s, JSON 0,24 s → 0,22 s, un tercio más de
  memoria); y nunca menos de 32 MB, porque con poco vivo la meta mínima de Go hacía un ciclo
  cada pocos megabytes, y cada uno despertaba un worker en cada procesador (el núcleo de Hugen,
  con menos de un megabyte vivo, tardó la mitad). Y **un map construido por un pliegue o un loop se construye en el lugar:** insertar
  en un árbol persistente copia el camino hasta la clave, veinte nodos en un map de un millón,
  pero los nodos que hizo el propio pliegue no los puede ver nadie más, así que el pliegue los
  cambia en vez de copiarlos (cada nodo guarda el dueño que lo hizo; ver `Data.Map`). El map del
  que parte, y todo map hecho antes, quedan como estaban (`examples/map-in-place.hgo`). Un
  millón de inserciones y borrados reservaban 1,4 GB; ahora 22 MB. `alter` y `adjust` también
  construyen en el lugar, y también un `Data.Set`, que es un map cuyos valores son `()`.
- **Una función recursiva que recibe una función conocida se copia para ella.** Una que le
  pasa un parámetro función tal cual a cada llamada a sí misma, como `insertWith` pasa su `f`,
  la llamaría a través de una clausura currificada en cada paso; si recibe una lambda que no usa
  variables locales, o una función de nivel superior, en tipos concretos, recibe una copia sin
  ese parámetro, con la función en su lugar, y sus llamadas copiadas adentro
  (`examples/specialise.hgo`). Las funciones de listas que la fusión vuelve loops quedan como
  están.
- **Las estructuras mutables** son más rápidas que los árboles de `Data.Map` para lo que sirven,
  y un loop sobre un vector mutable es el loop de Go. En un programa con hilos, un vector creado
  en IO toma un lock en cada acceso, salvo que ningún otro hilo pueda alcanzarlo, y el de la
  criba no puede (0,03 s sola, 0,04 s en un programa con hilos).

### Contra GHC

Los mismos programas escritos para GHC 9.12 (`ghc -O2`) están en `bench/ghc/`, y
`bench/ghc/run.sh` compila los dos y los mide lado a lado, en la misma máquina. Hacen el mismo
trabajo: los mismos algoritmos, los campos estrictos de Hago como campos estrictos en Haskell,
y los combinadores, la respuesta y el pretty printer del JSON portados línea por línea sobre
`Data.Text`.

| Programa | Hago | GHC |
|---|---|---|
| `nfib 40` | 0,37 s | 0,35 s |
| `nfib 40 :: (Ord a, Num a) => a -> a`, en `Int` | 0,37 s | 0,35 s |
| suma de los cuadrados de los múltiplos de 3 hasta 3.000.000, con listas perezosas | <0,01 s | <0,01 s |
| lo mismo sobre un `Data.Vector` (unboxed en GHC) | 0,02 s | 0,01 s |
| ternas pitagóricas hasta 400, como comprensión de listas | <0,01 s | <0,01 s |
| `foldr (+) 0 [1 .. 10000000]` | <0,01 s, 2 MB | 0,14 s, 169 MB |
| `foldr max 0 [1 .. 10000000]` | <0,01 s, 2 MB | 0,14 s, 169 MB |
| ``foldr (\x r -> x `mod` 7 + r) 0 [1 .. 10000000]`` | 0,03 s, 81 MB | 0,15 s, 169 MB |
| `mapM_` sobre un millón de elementos en IO | <0,01 s | <0,01 s |
| un loop recursivo en IO de cinco millones de iteraciones | <0,01 s | 0,01 s |
| lo mismo con dos funciones que se llaman entre sí | <0,01 s | 0,01 s |
| dos funciones puras que terminan llamándose entre sí, cien millones de veces | 0,03 s | 0,02 s |
| `mapM_` sobre un millón de elementos en `StateT Int IO` | <0,01 s | <0,01 s |
| cincuenta millones de sumas de un `Meters`, `newtype` o `data` | 0,02 s | 0,02 s |
| JSON, 3,7 MB, los mismos combinadores e impresor | 0,20 s, 100 MB | 0,29 s, 93 MB |
| `fib 32` dieciséis veces con `map` (GHC lo calcula una vez) | 0,13 s | 0,01 s |
| lo mismo, GHC sin full laziness | 0,12 s | 0,13 s |
| lo mismo con `parMap`, en 16 procesadores | 0,04 s | 0,05 s |
| un millón de inserciones en un `Data.Map`, medio millón de borrados, búsquedas | 0,34 s, 81 MB | 1,40 s, 218 MB |
| un millón de inserciones en un `Data.Set`, medio millón de borrados, búsquedas | 0,35 s, 80 MB | 1,20 s, 156 MB |
| los primos hasta un millón con un `Data.Map` | 0,37 s | 0,31 s |
| los primos hasta diez millones, sobre un `STVector` (`STUArray` en GHC) | 0,03 s | 0,04 s |
| lo mismo sobre un `IOVector` (`IOUArray`) | 0,03 s | 0,03 s |
| lo mismo, en un programa con hilos | 0,04 s | 0,04 s |
| frecuencias de un millón de números, en una tabla hash en ST | 0,10 s, 35 MB | 0,20 s, 44 MB |
| lo mismo con un `Data.Map` | 0,41 s | 0,57 s |
| el núcleo de Hugen, un millón de ticks de una pelea (`hago-examples`) | 5,0 s, 36 MB | 1,5 s, 9 MB |

- **Parejos:** el código estricto en tipos concretos, los newtypes, los pliegues de listas que
  se arman donde se pliegan (los dos los vuelven loops, también en IO y en `StateT`), los loops
  recursivos en IO, las funciones que terminan llamándose entre sí, los arreglos mutables, en
  ST, en IO y en un programa con hilos, `parMap`.
- **Adelante Hago:** un `Data.Map` o un `Data.Set` construido por un pliegue o un loop, que Hago
  construye en el lugar (de tres a cuatro veces más rápido, de un tercio a la mitad de la
  memoria); un `foldr` que es recursión, tomado desde el último elemento hacia atrás (cinco
  veces más rápido, con la mitad de la memoria, o ninguna sobre un rango); el parser y el
  impresor de JSON; la tabla hash; y la memoria donde hay mucho vivo.
- **Adelante GHC:** la criba con un map, por un quinto: lo que queda es el trabajo del propio
  map, los nodos de las claves que inserta y el rebalanceo, donde el recolector generacional de
  GHC anda mejor que el de Go. Un programa con poco vivo que reserva mucho llega a 35 MB, el
  piso del heap. Y un programa real, el motor de juegos de pelea Hugen portado línea por línea,
  por tres veces: hace 190 reservas de memoria por tick, cada una una llamada al
  asignador de Go, donde el de GHC mueve un puntero.

## Uso

Hace falta GHC (probado con 9.12) con cabal, y Go 1.25 o posterior (el CI prueba 1.25 y la más nueva).

```sh
cabal build
cabal run -v0 hago -- run examples/lazy.hgo                 # compilar y correr
cabal run -v0 hago -- build examples/lazy.hgo -o lazy.go    # sólo compilar
cabal run -v0 hago -- check examples/lazy.hgo              # sólo chequear los tipos
cabal run -v0 hago -- doc                                   # la referencia de la biblioteca, en docs/library
cabal run -v0 hago -- fmt --check examples/*.hgo            # qué archivos cambiaría hago fmt
cabal run -v0 hago -- repl                                  # evaluar expresiones a medida que se escriben
./check.sh                                                  # todos los ejemplos y los rechazados
```

`hago check ARCHIVO` chequea los tipos de un archivo y de los módulos que importa, y ahí se
detiene: no genera ni compila Go. Imprime el primer error como lo hace el compilador y sale con
1, o sale con 0 sin imprimir nada. Con el caché lleno tarda cerca de 0,05 s, así que un editor
lo puede correr cada vez que se guarda. El archivo puede ser un programa, uno de sus módulos
(`hago check examples/Data/Json.hgo` busca los imports de `Data.Json` desde `examples/`, porque
el módulo vive en `Data/Json.hgo`), un módulo de la biblioteca estándar (sus imports se leen de
`lib/`, al lado, así que una biblioteca que se está editando se chequea como está en el disco) o
el Prelude.

`hago doc` escribe la referencia del Prelude y de la biblioteca estándar en `docs/library`
(`-o DIR` la pone en otro lado): un archivo Markdown por módulo y un índice. Cada página lista lo
que exporta el módulo, en el orden de su código y bajo las secciones que el código marca con
líneas `-- Título -----`: funciones con sus tipos, tipos de datos con los constructores
exportados y todas sus instancias, clases con sus métodos. Los nombres y los tipos son los del
type checker, así que son exactos (un sinónimo aparece expandido, como `StateT s Identity`). El
texto es el bloque de comentarios que está justo arriba de cada declaración, y el comentario del
principio del archivo presenta el módulo. `check.sh` falla si las páginas que están en el
repositorio no son las que hace `hago doc`.

`hago fmt ARCHIVO...` cambia los espacios de los archivos en el lugar, y `hago fmt --check
ARCHIVO...` nombra los archivos que cambiaría y sale con 1, para el CI. Hace sólo lo que no puede
mover un token ni un comentario: un tab en el código se vuelve los espacios hasta la columna que
le da la regla de layout, se van los espacios al final de una línea, varias líneas en blanco
seguidas quedan en una, y el archivo termina con un solo salto de línea. Los literales de strings
y de caracteres y los comentarios quedan como están (salvo los espacios al final de una línea).
No vuelve a diagramar el código, para lo que hace falta un árbol de sintaxis que guarde los
comentarios y las formas que el parser traduce (ver `progress.md`). Antes de escribir, parsea el
resultado y chequea que el árbol de sintaxis y los comentarios sean los mismos y que formatearlo
de nuevo no cambie nada, y si no, se niega. `check.sh` lo corre sobre todos los `.hgo` del
repositorio.

### Editores

`editors/vscode` es una extensión de VS Code, JavaScript sin dependencias que se instala desde la
carpeta (ver [su README](editors/vscode/README.md), en inglés): resaltado, comentarios,
paréntesis e indentación para los archivos `.hgo`, y el error de `hago check` en el editor cada
vez que se guarda un archivo. Su gramática TextMate, `editors/vscode/syntaxes/hago.tmLanguage.json`,
conoce las formas propias de Hago (`foreign import go` y `foreign import go type`, `Lazy`, el `~`
de un campo perezoso, `p.name`), y la pueden usar otras herramientas que leen gramáticas TextMate.

### El REPL

```
hago> :t pure 3
pure 3 :: (Applicative f, Num a) => f a
hago> let double x = x + x
hago> double 2.5
5.0
hago> :load repl/Shapes.hgo
loaded repl/Shapes.hgo
hago> area (Rect 2.0 5.0)
10.0
hago> name <- getLine
Ada
hago> "hello, " ++ name
"hello, Ada"
```

`hago repl` guarda lo que se define (funciones, `data`, clases, instancias, imports) en un
módulo y lo chequea a medida que crece. Una expresión se compila con ese módulo en un programa
chico que la imprime, o que la ejecuta si es una acción, y Go lo corre: cerca de un tercio de
segundo cada vez. `:type` muestra el tipo con sus restricciones, `:load` trae las definiciones
de un archivo (y su `main`), que una definición en el prompt reemplaza, y `:{ ... :}` abarca
varias líneas. `:info` dice qué es un nombre (un tipo y sus instancias, una clase y sus
métodos), `:browse` lista lo que exporta un módulo y `:help` lista los comandos. No hay edición
de línea; `rlwrap hago repl` la agrega. Sin una terminal en la entrada, repite cada línea
después del prompt, así que la salida es una transcripción: `check.sh` reproduce las sesiones de
`repl/`.

`patrón <- acción` ejecuta la acción una vez y guarda lo que el patrón liga para las líneas
siguientes. Cada línea es un programa aparte, así que un valor no puede quedar en memoria: se
guarda como el texto que da `show`, en una definición que lo vuelve a leer con `read` con el
tipo que tenía. Hace falta Show y Read; una MVar, una función, una acción o un valor de Go no
se pueden guardar, y el REPL lo dice antes de ejecutar nada. La acción nunca se vuelve a
ejecutar: las líneas siguientes ven el valor, no la acción. Un tipo que la acción deja abierto
(`xs <- pure []`) hay que darlo, y definir un tipo de nuevo olvida los valores guardados de
ese tipo. Sin una terminal, una acción que lee la entrada estándar no encuentra nada: el REPL
la lee toda.

En `examples/` hay listas perezosas, ADTs con pattern matching y guardas, type classes, mónadas
(State, Maybe, Either, listas, reader, writer, Traversable), transformadores de mónadas, módulos,
records, newtypes, tuplas, rangos, listas por comprensión, llamadas a Go, archivos y loops.
`examples/json.hgo` es un programa más grande: un parser de JSON con errores que dicen dónde y qué
se esperaba (`examples/Text/Parser.hgo`, combinadores al estilo de Parsec) y un pretty-printer
(`examples/Text/Pretty.hgo`, el de Wadler, en la forma estricta de Lindig); dado un archivo
(`hago run examples/json.hgo ARCHIVO`), lo imprime con formato, como `jq .`.
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
  contextos, clases sobre tipos y sobre constructores de tipos, clases de varios parámetros con
  una dependencia funcional. `Int`, `Integer` (de cualquier tamaño, un `*big.Int` de Go), `Double`, `Char`, `String`, `Bool`.
- Operadores con declaraciones `infixl`/`infixr`/`infix`, secciones, backquotes, tuplas de hasta
  quince elementos (lo que pide Haskell 98; para más, un record), listas literales, y rangos (`[a ..]`, `[a, b ..]`, `[a .. c]`, `[a, b .. c]`) sobre cualquier `Enum`.
- Polimorfismo de let, con análisis de dependencias de las definiciones sin firma, también para
  las funciones locales: un helper local puede usarse en varios tipos y tener restricciones. Las
  funciones literales de Go no pueden ser genéricas, así que una función así pasa al nivel
  superior y recibe como parámetros extra las variables locales que usa.
- `foreign import go` y `foreign import go type`.
- Hilos, MVars, los canales de Go y `select`, `async` y `parMap`.
- Vectores (slices de Go) e iteradores (el `iter.Seq` de Go).
- Referencias, vectores y tablas de hash mutables, en IO y en ST, con un `runST` puro.

**Falta**
- **La recursión polimórfica a través de una restricción** (una función que se llama a sí misma
  en un tipo más grande) no se puede especializar, y se rechaza.
- **`String` es el `string` de Go, no `[Char]`.** Se convierte con `pack` y `unpack`.
- **No hay gestor de paquetes,** y la salida en Go es un solo archivo: la especialización necesita
  el programa entero, así que entre compilaciones sólo se guarda el chequeo de cada módulo.
- **Una mónada que se escribe como función, como `newtype State s a = State (s -> (a, s))`,
  suma un marco a la pila de Go por cada `>>=`,** porque Go no tiene llamadas de cola. Los loops
  largos en ella se escriben con `tailRecM`, o se la construye sobre los transformadores de la
  biblioteca, cuyos loops no consumen pila.
- **Una clase de varios parámetros necesita una dependencia funcional,** de uno de ellos a todos
  los demás, que es el que elige la instancia. `class Convert a b`, sin ninguna, se rechaza.
- **Algunas definiciones locales siguen siendo monomórficas:** los valores (como con la
  restricción de monomorfismo de Haskell, así se calculan una sola vez) y las funciones con
  restricciones sobre los tipos de la función que las contiene, cuyos diccionarios son de esa
  función.
- **Un valor polimórfico usado dentro de una función genérica se recalcula ahí,** en la variable
  de tipo de esa función. En tipos concretos se calcula una sola vez.
- **`Lazy` es un tipo de verdad.** La pereza sólo llega hasta donde la llevan los tipos. Por
  ejemplo, `foldr` toma `a -> Lazy b -> b` para poder cortar antes, y `++` y `<>` suspenden su
  segundo argumento. Como una variable de tipo nunca vale `Lazy t`, una función polimórfica
  pasada a `foldr` es estricta en el acumulador: `foldr const 0 [1 ..]` no termina, y
  `foldr (\x _ -> x) 0 [1 ..]` da `1`, porque una lambda toma el tipo contra el que se chequea.

## Organización del código

| Archivo | Qué hace |
|---|---|
| `src/Hago/Lexer.hs` | tokens y regla de layout |
| `src/Hago/Parser.hs` | Parsec sobre tokens, resolución de fixity |
| `src/Hago/Rename.hs` | módulos: importaciones, exportaciones y alcances, a nombres calificados |
| `src/Hago/Expand.hs` | sinónimos con `type`, que se expanden y desaparecen |
| `src/Hago/Derive.hs` | `deriving (Eq, Ord, Show, Read, Enum, Bounded, Functor, Foldable, Traversable)` |
| `src/Hago/TcMonad.hs` | unificación y el solver de restricciones (instancias, defaulting) |
| `src/Hago/Typecheck.hs` | inferencia y elaboración, donde se insertan `Lazy` y los diccionarios |
| `src/Hago/Core.hs` | el core tipado |
| `src/Hago/Specialize.hs` | copias del código sobre constructores de tipos; los métodos de instancia pasan a ser funciones |
| `src/Hago/Newtype.hs` | los newtypes, reemplazados por el tipo que envuelven |
| `src/Hago/Inline.hs` | las funciones chicas, copiadas en el código que las llama |
| `src/Hago/Lift.hs` | las funciones locales que sólo se llaman, llevadas al nivel superior |
| `src/Hago/CodeGen.hs` | generación de Go |
| `src/Hago/Cache.hs` | compilación separada: lo que da cada módulo, guardado en disco |
| `src/Hago/Driver.hs` | encontrar los módulos, compilar cada uno, y después el programa entero |
| `src/Hago/Doc.hs` | `hago doc`: la referencia de la biblioteca, desde el type checker y los comentarios |
| `src/Hago/Format.hs` | `hago fmt`: sólo espacios, chequeado para que no cambie el árbol de sintaxis ni los comentarios |
| `runtime/runtime.go` | listas e IO con trampolín; se copia en cada programa |
| `runtime/thunk_sequential.go` | thunks para un programa en una sola goroutine |
| `runtime/concurrent.go` | thunks que cualquier goroutine puede forzar, hilos, MVars, canales, `select` y `parMap`, para un programa que los usa |
| `runtime/lib_*.go` | lo que necesitan los hashes, las codificaciones, los procesos, el cliente HTTP y las estructuras mutables; se copia sólo en un programa que lo usa, para que no todo programa importe `net/http` o `crypto` |
| `prelude/Prelude.hgo` | el prelude, escrito en Hago |
| `lib/` | la biblioteca estándar (`Control.Monad.State` y compañía), escrita en Hago |
| `docs/library/` | la referencia de la biblioteca, hecha por `hago doc` |
| `editors/vscode/` | la extensión de VS Code: la gramática TextMate, y `hago check` al guardar |
| `bench/json-input.go` | escribe el JSON del benchmark de [Performance](#performance) |
| `bench/run.sh` | los programas de [Performance](#performance), compilados y medidos, con un compilador o con varios lado a lado |
| `bench/ghc/` | los mismos programas para GHC, y `run.sh`, que los mide contra los de Hago |

## Licencia

MIT. Ver [LICENSE](LICENSE).
