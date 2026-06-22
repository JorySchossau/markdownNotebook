## The processing pipeline: how a save flows through the system. The per-stage
## transforms (collate sources, mark dirty cells, show wait messages) and the
## `process` orchestrator that runs them in order. See agents.md §4 for the full
## pipeline diagram. The safe-IO write primitive lives in `mdnb_io.nim`.

## ==============

proc collateSources(md: var MarkdownFile) =
  ## Glue cells into per-target source strings. A `source:` cell fully defines
  ## its file (last one in document order wins); an `append:` cell adds its
  ## content onto whatever `source:`/`append:` already established for that
  ## target. Auto-generated sources (no explicit `source:`/`append:`) are unique
  ## per cell, so they can't collide.
  ##
  ## Also builds `sourceSigs`: for each source the combined command signature of
  ## every cell writing it (see `cellSignature`). The signature captures the
  ## language id and all commands/args — everything about a cell EXCEPT its body
  ## and its `[s/r/x/k]` state. `markDirtyCells` compares it alongside the body so
  ## that editing a command (e.g. `timeout:5`→`timeout:30`, or the language id)
  ## marks the cell dirty and re-runs it, even though the body — and thus the
  ## generated source file — is byte-identical. The state field is deliberately
  ## excluded (mdnb flips it itself).
  for cell in md.cells:
    if not cell.properties.code: continue
    let source = cell.properties.source
    if cell.properties.isAppend:
      md.sources[source] = md.sources.getOrDefault(source) & md.content(cell) & '\n'
      md.sourceSigs[source] = md.sourceSigs.getOrDefault(source) & cell.properties.cellSignature & "\x00"
    else:
      md.sources[source] = md.content(cell) & '\n'
      md.sourceSigs[source] = cell.properties.cellSignature & "\x00"
    md.cellsWritingToSource[source] = md.cellsWritingToSource.getOrDefault(source) + 1

proc markDirtyCells(md: var MarkdownFile) =
  ## Mark a code cell dirty if its own source/output file is missing or the
  ## regenerated source would differ from what's on disk (as before), and then
  ## propagate that through the cell dependency graph: a cell is also dirty when
  ## a cell whose `output:` it consumes has changed.
  ##
  ## The dependency edge is `inputs:` -> `output:`: a cell declares what it
  ## consumes via `inputs:f1,f2,...` (comma-separated, no spaces), and depends on
  ## any cell that `output:`s one of those files. (`inputs:` is the right signal
  ## here precisely because mdnb never writes a cell's input files — they are
  ## pure inputs — whereas a cell's own `source:`/`output:` are files it
  ## *writes*, so those would be write/write conflicts, not dependencies.)
  ## Propagation runs to a fixed point so chains are covered. It is safe to
  ## over-approximate dirtiness (an extra rerun is correct); the opposite (a
  ## stale cell) is the bug.
  ##
  ## Command-signature check: a non-ephemeral cell is ALSO dirty when its command
  ## signature (language id + all commands/args — see `cellSignature`) differs
  ## from the one recorded on the last run. The previous signature is persisted
  ## in a sidecar file (`<source>.mdnbsig`) written alongside the source whenever
  ## the cell runs. This makes editing a command — `timeout:5`→`timeout:30`, a
  ## language-id change, a new `inputs:` — mark the cell dirty and re-run it even
  ## though the body (and thus the generated source file) is byte-identical.
  ## Ephemeral (bare) cells need no sidecar: their cache FILENAME already embeds
  ## the signature (via `contentHash`), so a command edit changes the filename,
  ## the old file is orphaned, and the new one is missing -> dirty.
  for i in 0 ..< md.cells.len:
    if not md.cells[i].properties.code: continue
    let source = md.cells[i].properties.source
    let output = md.cells[i].properties.output
    let ephemeral = md.cells[i].properties.ephemeral
    # An ephemeral (bare-block) cell has no `output:` file, so only its source
    # cache file gates dirtiness: it is dirty iff the source is missing or its
    # content differs from what's cached on disk. That missing/differ check is
    # exactly the cache — an unchanged bare block re-saved does not re-run.
    if not fileExists(source) or (not ephemeral and not fileExists(output)):
      md.cells[i].properties.dirty = true
    elif readFile(source) != md.sources[source]:
      md.cells[i].properties.dirty = true
    elif not ephemeral and md.sourceSigs[source] != sigSidecar(source):
      # Command/config changed since the last run (body is identical, but a
      # command/arg/language-id edit moved the signature). Re-run so the new
      # command takes effect. Sidecar may be absent on a first-ever run or after
      # `:clean`; `sigSidecar` returns "" then, which differs from any real sig,
      # so the cell is (correctly) treated as dirty.
      md.cells[i].properties.dirty = true
  # Producer index keyed by produced file. A cell produces its `output:` file.
  var producer: Table[string, int]
  for i, cell in md.cells:
    if cell.properties.code and cell.properties.output.len > 0:
      producer[cell.properties.output] = i
  # Fixed-point propagation: a clean cell becomes dirty when a cell producing
  # any of its `inputs:` files is dirty.
  var changed = true
  while changed:
    changed = false
    for i, cell in md.cells:
      if not cell.properties.code or cell.properties.dirty: continue
      for input in cell.properties.inputs:
        let dep = producer.getOrDefault(input, -1)
        if dep >= 0 and md.cells[dep].properties.dirty:
          md.cells[i].properties.dirty = true
          changed = true
          break

proc showWaitMessages(md: var MarkdownFile) =
  ## Write "(please wait)" into the `show:` cell of every code cell that will
  ## actually run this pass, so the user sees immediate feedback before async
  ## output lands. Under the Tier 4 stopped-by-default model a dirty `[s]` cell
  ## does NOT run, so it must NOT get a "(please wait)" (it would never be
  ## cleared — nothing runs to replace it). Only cells `cellShouldRun` accepts —
  ## `[x]`, the `-o` force-run-all, or a bulk-run cell flipped to `[x]` — get it.
  for i, codeCell in md.cells:
    if not codeCell.properties.code: continue
    if not cellShouldRun(codeCell): continue
    for j, showCell in md.cells:
      if showCell.properties.code: continue
      if showCell.properties.show == codeCell.properties.output:
        md.writeIntoCell(j, "(please wait)")
  md.write

proc cellInfoLineRange(md: MarkdownFile; idx: int): HSlice[int, int] =
  ## Byte range of the info-string line (the fence opener, e.g.
  ## `` ```python [s] source:foo.py ``) for cell `idx`. The cell's `rng.a` is the
  ## first body byte; the byte before it is the `\n` ending that line, so the
  ## line spans from the `\n` after the previous line up to (not including) that
  ## terminator. Returned range is inclusive on both ends and never includes the
  ## terminating `\n`. Used by `injectStoppedState` to find where to splice the
  ## `[s]` field, and shares its back-scan logic with `writeCellState`.
  let cell = md.cells[idx]
  var lineStart = cell.rng.a - 1
  if lineStart > 0 and md.buf[][lineStart] == '\n': dec lineStart  # skip the line-terminating \n
  while lineStart > 0 and md.buf[][lineStart - 1] != '\n': dec lineStart
  let lineEnd = cell.rng.a - 1            # the \n ending the info line (exclusive below)
  lineStart ..< lineEnd

proc injectStoppedState(md: var MarkdownFile) =
  ## Tier 4 stopped-by-default: ensure every runnable code cell carries a `[s]`
  ## (stopped) state field so the notebook is inert until the user asks it to run.
  ## A runnable cell is one whose language is a registered runtime or `raw`
  ## (`props.code == true`); a fenced block whose language isn't registered stays
  ## inert and gets no placeholder, matching today's "unregistered = nothing runs".
  ##
  ## For each runnable cell whose info-string line has NO `[ ]` field, splice
  ## ` [s]` in immediately after the language id (the first whitespace-delimited
  ## token after the fence marker) and before any other commands, e.g.
  ## `` ```sh `` -> `` ```sh [s] `` and
  ## `` ```python output:simulation.txt `` -> `` ```python [s] output:simulation.txt ``.
  ## Idempotent: a cell that already has a `[ ]` field is left alone, so repeated
  ## saves never double up. Each splice grows the buffer, so downstream cell byte
  ## offsets are patched via `updatePositionsByOffset` (same as `replaceShortcuts`
  ## / `writeIntoCell`). The buffer is written once at the end so the placeholder
  ## appears in the user's editor; the watch loop's self-write-ignoring logic in
  ## `main` keeps mdnb's own write from feedback-looping.
  var changed = false
  for i in 0 ..< md.cells.len:
    let cell = md.cells[i]
    if not cell.properties.code: continue
    let lineRange = md.cellInfoLineRange(i)
    let line = md.buf[][lineRange]
    # A fence opener is `fence + lang + rest`. Find the fence (``` or ~~~), skip
    # it and any spaces, take the language token, then splice right after it.
    # First: is there already a `[ ]` field anywhere on this line? If so skip.
    var k = 0
    var hasField = false
    while k < line.len:
      if line[k] == '[':
        # a state field is `[` + one char + `]`
        if k + 2 < line.len and line[k + 2] == ']': hasField = true; break
      inc k
    if hasField: continue
    # Locate the fence marker and the end of the language id following it.
    var p = 0
    while p < line.len and line[p] in {' ', '\t'}: inc p            # leading ws (rare)
    if p < line.len and line[p] == '`':
      while p < line.len and line[p] == '`': inc p
    elif p < line.len and line[p] == '~':
      while p < line.len and line[p] == '~': inc p
    else:
      continue   # not a fence opener we recognize; leave it alone
    while p < line.len and line[p] in {' ', '\t'}: inc p            # ws after fence
    let langStart = p
    while p < line.len and line[p] notin {' ', '\t'}: inc p         # the language id
    let langEnd = p                                                 # one past the id
    if langEnd == langStart: continue                               # no language id
    # Splice ` [s]` at absolute buffer offset (lineRange.a + langEnd). The splice
    # sits in the info-string line, BEFORE this cell's body (`rng.a`), so this
    # cell AND every later one must shift by the inserted length (4 bytes for
    # " [s]"). `updatePositionsByOffset` starts at the given index inclusive, so
    # pass `i` (not `cell.id`) to include the current cell.
    let spliceAt = lineRange.a + langEnd
    md.buf[] = md.buf[][0 ..< spliceAt] & " [s]" & md.buf[][spliceAt .. ^1]
    md.updatePositionsByOffset(i, 4)
    changed = true
  if changed: md.write

## ==============

proc runBulk(md: var MarkdownFile): bool =
  ## Tier 4 bulk-run dispatch: if one of `:runall`/`:runabove`/`:runbelow` was
  ## seen this pass (runMode set by `replaceShortcuts`), select the target cells
  ## in document order and run them sequentially (visible x -> r -> s per cell),
  ## then clear the flag. Returns true if a bulk run happened (so `process` skips
  ## the normal non-blocking `runCells` for this pass). `runBoundaryAt` is the
  ## cell index of the first cell at/below the command line: `:runabove` selects
  ## indices < boundary, `:runbelow` selects indices >= boundary.
  result = false
  case md.runMode
  of rmAll:
    var sel: seq[int] = @[]
    for i, c in md.cells:
      if c.properties.code: sel.add i
    md.runCellsSequential(sel)
    result = true
  of rmAbove:
    var sel: seq[int] = @[]
    for i, c in md.cells:
      if i < md.runBoundaryAt and c.properties.code: sel.add i
    md.runCellsSequential(sel)
    result = true
  of rmBelow:
    var sel: seq[int] = @[]
    for i, c in md.cells:
      if i >= md.runBoundaryAt and c.properties.code: sel.add i
    md.runCellsSequential(sel)
    result = true
  of rmNone: discard
  md.runMode = rmNone
  md.runBoundaryAt = 0

proc process(md: var MarkdownFile) =
  md.processYamlHeader
  md.processBodyForCells
  md.replaceShortcuts
  md.processBodyForCells
  if md.cleanBuild:
    md.clearAllFiles
    md.cleanBuild = false
  md.injectStoppedState   # Tier 4: runnable cells get `[s]` if they lack a `[ ]` field
  md.collateSources
  md.markDirtyCells
  md.showWaitMessages
  if not md.runBulk:      # Tier 4: a bulk command runs its scope sequentially this pass
    md.runCells
  md.write
