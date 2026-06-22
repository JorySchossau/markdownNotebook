## The data model: the four core types plus the buffer-mutation primitives that
## splice text into a cell while patching every later cell's byte offset. See
## agents.md §5 for the model overview and the `ref string` buffer rationale.
##
## Plain-old-data fields, not `Option[T]`: every value has a logical default, so
## `nil` doesn't add meaning. The four string fields default to `""` and are
## simply checked with `.len == 0` (a cell with no `output:` has an empty
## `output`, etc.). `timeout` defaults to `defaultTimeout` seconds and is read
## directly. This keeps the data model free of the unwrap/`some` ceremony that
## `Option[T]` would force on every call site.
const defaultTimeout = 5      ## seconds; the `timeout:` a cell gets when it has none
const defaultTrimLines = 50   ## the `trim:head,N` line count a cell gets when it has none

type CellProperties = object
  dirty: bool
  code: bool
  isAppend: bool
  ephemeral: bool   ## bare-block cell (no `source:`/`append:`/`output:`): mdnb
                    ## generates a tmp source in the current directory and runs
                    ## it for its side effects. The tmp file is kept as a CACHE
                    ## (content-hash in its name) so an unchanged block doesn't
                    ## re-run; `:clean` wipes it. No `output:` is kept.
  inputs: seq[string]
  language, output, source, show: string   ## "" = absent (no such command given)
  timeout: int   ## `timeout:N` in seconds; defaults to `defaultTimeout`.
  trimTail: bool   ## `trim:tail,N` (true) vs `trim:head,N` (false, the default).
  trimLines: int   ## `trim:head,N` / `trim:tail,N` line count; defaults to `defaultTrimLines`.
  state: char   ## `[ ]` field after the lang/id in the info string (see §7/§12).
               ## '\0' = absent: dirty-driven auto-run (today's behavior).
               ## 's' = stopped (won't auto-run), 'r' = running (mdnb-set),
               ## 'x' = execute (force run), 'k' = kill the running process.

type Cell = object
  id: int
  rng: HSlice[int, int]
  properties: CellProperties

type Runtime = object
  command: string
  extension: string

type MarkdownFile = object
  filename: string
  buf: ref string
  cells: seq[Cell]
  runtimes: Table[string, Runtime]
  sources: Table[string, string]
  cellsWritingToSource: Table[string, int]
  cleanBuild: bool

## ==============

proc content(md: MarkdownFile; cell: Cell): string = md.buf[][cell.rng]

## ==============

proc updatePositionsByOffset(md: var MarkdownFile; cellposition, fileoffset: int) =
  for i in cellposition ..< md.cells.len:
    md.cells[i].rng.a += fileoffset
    md.cells[i].rng.b += fileoffset

proc writeIntoCell(md: var MarkdownFile; idx: int; value: string) =
  let cell = md.cells[idx].addr
  md.buf[] = md.buf[][0 .. cell.rng.a - 1] & value & '\n' & md.buf[][cell.rng.b + 1 .. ^1]
  let deltaOffset = value.len + 1 - (cell.rng.b - cell.rng.a + 1)
  cell.rng.b = cell.rng.a + value.len
  md.updatePositionsByOffset(cell.id, deltaOffset)
