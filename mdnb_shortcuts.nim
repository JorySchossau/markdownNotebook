## Shortcut expansion and clean build. `replaceShortcuts` rewrites bare
## `show:file` text (to an image link or an empty `show:` block) and `:clean`
## lines, running in the gaps between already-parsed cells; `clearAllFiles` is
## the `:clean` handler that deletes every generated source/output file.
##
## A bare `show:file` (non-image) is expanded to an *empty* `show:` block; the
## file's contents are read in later by `runCells`, streamed through the cell's
## trim window so an enormous file is never pulled fully into the buffer here.
import std/random
type ShortcutKind = enum skShow, skClean, skRunAll, skRunAbove, skRunBelow
proc replaceShortcuts(md: var MarkdownFile) =
  var pos: tuple[first, last: int]
  var endPrevChunk, startNextChunk = 0
  var matches = newSeq[string](1)
  # use the html version for now as we explore how to force a cache update of the md viewer
  #let (showimg, clean) = ("![$1]($1)\n", "")
  randomize()
  let (showimg, clean) = ("<img src=\"$1\" width=100% alt=\"" & $rand(1000) & "\">\n", "")
  # Tier 4 global run commands collapse to the empty string (line removed), like
  # `:clean`, but each sets a MarkdownFile flag the bulk-run step reads. The
  # `:runabove`/`:runbelow` offset is captured from `fragpos` at removal time so
  # "above"/"below" maps to a cell boundary. PEG objects have no usable `==`, so
  # carry a `ShortcutKind` tag alongside each pattern and dispatch on the tag.
  let rules = [(skShow, bareShowPattern, showimg), (skClean, cleanPattern, clean),
               (skRunAll, runAllPattern, clean), (skRunAbove, runAbovePattern, clean),
               (skRunBelow, runBelowPattern, clean)]
  for cell_i in 0 .. md.cells.len:
    startNextChunk = if cell_i == md.cells.len: md.buf[].len - 1
                     else: md.cells[cell_i].rng.a
    for (kind, pattern, replacement) in rules.items:
      pos = (-1, 0)
      while true:
        matches[0] = ""
        pos = md.buf[][endPrevChunk .. startNextChunk].findBounds(pattern, matches, start = pos.last)
        if pos.first == -1: break
        let fragpos = (endPrevChunk + pos.first + 1, endPrevChunk + pos.last)
        let newvalue =
          if kind != skShow or splitFile(matches[0]).ext in imageExt:
            replacement % matches
          else:
            # Non-image bare `show:file`: emit an empty `show:` block whose body
            # `runCells` fills by streaming the file through its trim window.
            "```show:" & matches[0] & "\n```\n"
        let deltaOffset = newvalue.len - (fragpos[1] - fragpos[0]) - 1
        md.buf[] = md.buf[][0 .. fragpos[0] - 1] & newvalue & md.buf[][fragpos[1] + 1 .. ^1]
        pos = (pos.first, pos.first + newvalue.len)
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, deltaOffset)
        startNextChunk += deltaOffset
        case kind
        of skClean: md.cleanBuild = true
        of skRunAll: md.runMode = rmAll
        # cell_i is the index of the first cell at or below this command line
        # (the gap being scanned is the prose BEFORE cell cell_i), so it's exactly
        # the boundary between "above" and "below" cells. Capturing the INDEX
        # (not the byte offset) is robust to the offset shifts that happen as the
        # command line is removed and downstream cells are repositioned.
        of skRunAbove: md.runMode = rmAbove; md.runBoundaryAt = cell_i
        of skRunBelow: md.runMode = rmBelow; md.runBoundaryAt = cell_i
        else: discard
    endPrevChunk = startNextChunk

proc clearAllFiles(md: MarkdownFile) =
  var seen: HashSet[string]
  for cell in md.cells:
    if cell.properties.code:
      let source = cell.properties.source
      # Ephemeral bare-block sources are cache files in the cwd (one per distinct
      # body); wipe them on `:clean` too so the cache is fully reset. The output
      # of an ephemeral cell is empty (""), so guard it rather than removeFile("").
      if source.len > 0 and source notin seen:
        seen.incl source
        source.tryRemoveFile
        # The command-signature sidecar (see `sigSidecar`/`markDirtyCells`) sits
        # next to the source; sweep it on `:clean` so a clean build re-runs every
        # cell from a known-empty signature state (sidecar absent -> dirty).
        sigSidecarPath(source).tryRemoveFile
      let output = cell.properties.output
      if output.len > 0: output.tryRemoveFile
