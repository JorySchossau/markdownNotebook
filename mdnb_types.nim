## The data model: the four core types plus the buffer-mutation primitives (agents.md §5). Plain-old-data fields, not `Option[T]` (see "Do NOT Use" in agents.md): every value has a logical default.
const defaultTimeout = 5      ## seconds; the `timeout:` a cell gets when it has none
const defaultTrimLines = 50   ## the `trim:head,N` line count a cell gets when it has none

type RunMode = enum   ## Tier 4 bulk-run scope set by `:runall`/`:runabove`/`:runbelow`
  rmNone, rmAll, rmAbove, rmBelow

type CellProperties = object
  dirty: bool
  code: bool
  isAppend: bool
  ephemeral: bool   ## bare-block cell: mdnb runs a content-hash-named tmp source for side effects; no `out:` kept; wiped by `:clean`.
  inputs: seq[string]
  language, output, source, show: string   ## "" = absent (no such command given)
  timeout: int   ## `timeout:N` in seconds; defaults to `defaultTimeout`.
  trimTail: bool   ## `trim:tail,N` (true) vs `trim:head,N` (false, the default).
  trimLines: int   ## `trim:head,N` / `trim:tail,N` line count; defaults to `defaultTrimLines`.
  # Two-field control `[T](S)` after the language id. `trigger` T: '\0'=absent, ' '=do-nothing, 'x'=run on every save (sticky), 'o'=run once. `state` S: '\0'=absent, 's'=stopped, 'r'=running, 'k'=kill. A cell runs this pass iff trigger∈{x,o} AND state=='s'. See agents.md §7.
  trigger: char
  state: char
  parallel: bool   ## `parallel` modifier: in the sequential run modes (`:runall`/`:runabove`/`:runbelow`/`-o`) this cell is launched but NOT waited on before the next cell launches; only the final barrier waits for it. No-op in the default async save path (already concurrent).

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
  sourceSigs: Table[string, string]   ## per-source combined command signature; the command half of the dirtiness check (body is the other).
  cellsWritingToSource: Table[string, int]
  cleanBuild: bool
  # Tier 4 bulk-run scope set by `replaceShortcuts` (removes the line, records cell INDEX boundary + which mode). See agents.md §12 Tier 4.
  runMode*: RunMode
  runBoundaryAt*: int

## ==============

proc content(md: MarkdownFile; cell: Cell): string = md.buf[][cell.rng]

proc cellSignature(props: CellProperties): string =
  ## Stable string over the language id and ALL commands/args (NOT body, NOT state); the command half of the dirtiness check (body is the other).
  var parts: seq[string] = @[]
  parts.add "lang=" & props.language
  if props.isAppend: parts.add "append=" & props.source
  elif props.source.len > 0: parts.add "source=" & props.source
  if props.output.len > 0: parts.add "out=" & props.output
  if props.show.len > 0: parts.add "show=" & props.show
  if props.inputs.len > 0: parts.add "in=" & props.inputs.join(",")
  parts.add "timeout=" & $props.timeout
  parts.add "trim=" & (if props.trimTail: "tail," else: "head,") & $props.trimLines
  if props.parallel: parts.add "parallel=true"
  parts.join("|")

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
