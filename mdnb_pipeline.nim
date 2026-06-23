## The processing pipeline: how a save flows through the system. Per-stage transforms (collate sources, mark dirty, show wait) and the `process` orchestrator (agents.md §4).

## ==============

proc collateSources(md: var MarkdownFile) =
  ## Glue cells into per-target source strings: `source:` defines a file (last in document order wins), `append:` adds to it; auto-generated sources are unique per cell. Also builds `sourceSigs` — the combined command signature per source (see `cellSignature`) so editing a command re-runs even with an identical body.
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
  ## Mark a code cell dirty if its source/output is missing, the regenerated source differs from disk, or its command signature differs from the sidecar; then propagate through the `in:`->`out:` dependency graph to a fixed point. (Over-approximating dirtiness is safe; a stale cell is the bug.) Ephemeral cells have no sidecar — their cache filename embeds the signature.
  for i in 0 ..< md.cells.len:
    if not md.cells[i].properties.code: continue
    let source = md.cells[i].properties.source
    let output = md.cells[i].properties.output
    let ephemeral = md.cells[i].properties.ephemeral
    # Ephemeral cell: no output file; dirty iff the source cache is missing or differs from disk.
    if not fileExists(source) or (not ephemeral and not fileExists(output)):
      md.cells[i].properties.dirty = true
    elif readFile(source) != md.sources[source]:
      md.cells[i].properties.dirty = true
    elif not ephemeral and md.sourceSigs[source] != sigSidecar(source):
      # Command/config changed since last run (body identical). Absent sidecar (first run / after `:clean`) reads as "" -> dirty.
      md.cells[i].properties.dirty = true
  # Producer index keyed by produced file (a cell produces its `out:` file).
  var producer: Table[string, int]
  for i, cell in md.cells:
    if cell.properties.code and cell.properties.output.len > 0:
      producer[cell.properties.output] = i
  # Fixed-point propagation: a clean cell becomes dirty when a cell producing any of its `in:` is dirty.
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
  ## Write "(please wait)" into the `show:` cell of every code cell that will actually run this pass (gated on `cellShouldRun`, so a stopped `[s]` cell never gets one — it would never be cleared).
  for i, codeCell in md.cells:
    if not codeCell.properties.code: continue
    if not cellShouldRun(codeCell): continue
    for j, showCell in md.cells:
      if showCell.properties.code: continue
      if showCell.properties.show == codeCell.properties.output:
        md.writeIntoCell(j, "(please wait)")
  md.write

proc cellInfoLineRange(md: MarkdownFile; idx: int): HSlice[int, int] =
  ## Byte range of the info-string line (the fence opener) for cell `idx`; shared back-scan logic used by `injectDefaultStateField` and `writeStateField`.
  let cell = md.cells[idx]
  var lineStart = cell.rng.a - 1
  if lineStart > 0 and md.buf[][lineStart] == '\n': dec lineStart  # skip the line-terminating \n
  while lineStart > 0 and md.buf[][lineStart - 1] != '\n': dec lineStart
  let lineEnd = cell.rng.a - 1            # the \n ending the info line (exclusive below)
  lineStart ..< lineEnd

proc injectDefaultStateField(md: var MarkdownFile) =
  ## Ensure every runnable cell (a cell whose language is registered in the frontmatter `code:` runtimes) carries the two-field `[T](S)` control right after its language id. Two cases per cell:
  ##  - no control at all: splice ` [x](s)` — the common first-save case. `x` is sticky (run on every save), so a freshly-saved registered-language cell runs immediately and keeps running on each subsequent save until the user blanks the trigger. (A plain codefence whose language is NOT registered has `props.code == false`, so it is skipped here — no injection, it stays inert.)
  ##  - a shorthand `[](S)` (empty brackets, no trigger char): canonicalize to `[ ](S)` so the blank trigger the user typed is explicit (this is a user- authored do-nothing, not a fresh cell, so it is NOT promoted to `x`).
  ## A full `[T](S)` control is left untouched. Each splice/canonicalize patches downstream offsets via `updatePositionsByOffset`.
  var changed = false
  for i in 0 ..< md.cells.len:
    let cell = md.cells[i]
    if not cell.properties.code: continue   # plain codefence (unregistered language): no injection
    let lineRange = md.cellInfoLineRange(i)
    let line = md.buf[][lineRange]
    # Find the first `[` on the info line and the `]` that closes it, then check whether `(...)` follows — that is the `[T](S)` control. The PEG already validated any present control's content, so here we only care about shape: present+canonical (leave), present+shorthand `[](S)` (canonicalize to blank), or absent (inject `[x](s)`).
    var bracket = -1
    var closeB = -1
    for k in 0 ..< line.len:
      if line[k] == '[' and bracket == -1: bracket = k
      elif bracket != -1 and line[k] == ']': closeB = k; break
    if bracket != -1 and closeB != -1 and closeB + 1 < line.len and line[closeB + 1] == '(':
      # A `[...](...)` control is present. Only the shorthand `[](S)` (empty brackets, `bracket+1 == closeB`) needs canonicalizing to `[ ](S)`; any `[T](S)` is already canonical.
      if closeB - bracket == 1:   # `[]`: no trigger char between the brackets
        let spliceAt = lineRange.a + bracket + 1
        md.buf[] = md.buf[][0 ..< spliceAt] & " " & md.buf[][spliceAt .. ^1]
        md.updatePositionsByOffset(i, 1)
        changed = true
      continue
    # No `[T](S)` control: splice ` [x](s)` right after the language id (sticky `x` so a fresh registered-language cell runs on every save).
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
    # Splice ` [x](s)` before this cell's body, so this cell AND every later one shifts by 7 bytes; pass `i` (not cell.id) to include the current cell. Also set the in-memory trigger/state so `cellShouldRun` (run later this same `process` pass) sees the freshly-injected `x` and runs the cell.
    let spliceAt = lineRange.a + langEnd
    md.buf[] = md.buf[][0 ..< spliceAt] & " [x](s)" & md.buf[][spliceAt .. ^1]
    md.updatePositionsByOffset(i, 7)
    md.cells[i].properties.trigger = 'x'
    md.cells[i].properties.state = 's'
    changed = true
  if changed: md.write

## ==============

proc runBulk(md: var MarkdownFile): bool =
  ## Tier 4 bulk-run dispatch: if a `:run*` command set `runMode`, select the target cells in document order and run them sequentially (visible x->r->s per cell), then clear the flags. Returns true if a bulk run happened (so `process` skips the non-blocking `runCells`).
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
  md.injectDefaultStateField   # runnable cells get `[ ](s)` if they lack a `[T](S)` control
  md.collateSources
  md.markDirtyCells
  md.showWaitMessages
  if not md.runBulk:      # Tier 4: a bulk command runs its scope sequentially this pass
    md.runCells
  md.write
