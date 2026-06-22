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
  for codeCell in md.cells:
    if not (codeCell.properties.code or codeCell.properties.dirty): continue
    for i, showCell in md.cells:
      if showCell.properties.code: continue
      if showCell.properties.show == codeCell.properties.output:
        md.writeIntoCell(i, "(please wait)")
  md.write

## ==============

proc process(md: var MarkdownFile) =
  md.processYamlHeader
  md.processBodyForCells
  md.replaceShortcuts
  md.processBodyForCells
  if md.cleanBuild:
    md.clearAllFiles
    md.cleanBuild = false
  md.collateSources
  md.markDirtyCells
  md.showWaitMessages
  md.runCells
  md.write
