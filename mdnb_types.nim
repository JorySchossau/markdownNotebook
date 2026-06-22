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
  sourceSigs: Table[string, string]          ## per-source combined command signature (see
                                             ## `cellSignature`); the command half of the
                                             ## dirtiness check — body is the other half
  cellsWritingToSource: Table[string, int]
  cleanBuild: bool
  # Tier 4 bulk-run commands: `:runall` / `:runabove` / `:runbelow` on their own
  # line. `replaceShortcuts` removes the line and sets exactly one of these. The
  # run step (after markDirtyCells) reads them, runs the selected cells in
  # document order, and clears them. `runAll` is a plain flag (all cells);
  # `runAboveAt`/`runBelowAt` carry the byte offset of the command line BEFORE
  # removal, so "above"/"below" maps to a cell boundary (cells whose body starts
  # before / at-or-after that offset). -1 = no such command this pass.
  runAll: bool
  runAboveAt: int
  runBelowAt: int

## ==============

proc content(md: MarkdownFile; cell: Cell): string = md.buf[][cell.rng]

proc cellSignature(props: CellProperties): string =
  ## A stable string capturing every user-authored facet of a cell — its language
  ## id and ALL commands/arguments (source/append, output, inputs, timeout, trim) —
  ## used for dirtiness hashing alongside the body. Changing any command/arg changes
  ## this signature, which makes the cell dirty on the next save so it re-runs (the
  ## fix for "I edited a command but the cell didn't re-run").
  ##
  ## Crucially EXCLUDES the `[s/r/x/k]` `state` field: mdnb flips that itself
  ## (`x`→`r`→`s`) on every run, so including it would mark every just-run cell
  ## dirty again and feedback-loop. The body is NOT part of the signature — it is
  ## folded in separately at the call site (it lives in the buffer, not here) — so
  ## the signature is purely the command/config half and the body is the other.
  ## The derived flags `code`/`dirty`/`ephemeral` are excluded too (they are
  ## consequences of the commands, not independent inputs).
  var parts: seq[string] = @[]
  parts.add "lang=" & props.language
  if props.isAppend: parts.add "append=" & props.source
  elif props.source.len > 0: parts.add "source=" & props.source
  if props.output.len > 0: parts.add "output=" & props.output
  if props.show.len > 0: parts.add "show=" & props.show
  if props.inputs.len > 0: parts.add "inputs=" & props.inputs.join(",")
  parts.add "timeout=" & $props.timeout
  parts.add "trim=" & (if props.trimTail: "tail," else: "head,") & $props.trimLines
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
