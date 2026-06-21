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
  for cell in md.cells:
    if not cell.properties.code: continue
    let source = cell.properties.source.get
    if cell.properties.isAppend:
      md.sources[source] = md.sources.getOrDefault(source) & md.content(cell) & '\n'
    else:
      md.sources[source] = md.content(cell) & '\n'
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
  for i in 0 ..< md.cells.len:
    if not md.cells[i].properties.code: continue
    let source = md.cells[i].properties.source.get
    let output = md.cells[i].properties.output.get
    if not fileExists(source) or not fileExists(output):
      md.cells[i].properties.dirty = true
    elif readFile(source) != md.sources[source]:
      md.cells[i].properties.dirty = true
  # Producer index keyed by produced file. A cell produces its `output:` file.
  var producer: Table[string, int]
  for i, cell in md.cells:
    if cell.properties.code and cell.properties.output.isSome:
      producer[cell.properties.output.get] = i
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
