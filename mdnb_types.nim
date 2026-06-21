## The data model: the four core types plus the buffer-mutation primitives that
## splice text into a cell while patching every later cell's byte offset. See
## agents.md §5 for the model overview and the `ref string` buffer rationale.
type CellProperties = object
  dirty: bool
  code: bool
  isAppend: bool
  inputs: seq[string]
  language, output, source, show: Option[string]
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
