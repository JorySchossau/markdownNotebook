## Shortcut expansion and clean build. `replaceShortcuts` rewrites bare `show:file` (to an image link or empty `show:` block) and `showhtml:file` (to an HTML img tag), and consumes `:clean` / `:run*` lines, scanning only the prose gaps between cells; `clearAllFiles` is the `:clean` handler. A bare non-image `show:file` becomes an empty `show:` block filled later by `runCells` (streamed through its trim window).
type ShortcutKind = enum skShow, skShowHtml, skClean, skRunAll, skRunAbove, skRunBelow
proc replaceShortcuts(md: var MarkdownFile) =
  var pos: tuple[first, last: int]
  var endPrevChunk, startNextChunk = 0
  var matches = newSeq[string](1)
  let (showimg, showimgHtml, clean) = ("![$1]($1)\n", "<img src=\"$1\" width=100%>\n", "")
  # Tier 4: `:run*` lines collapse to "" (removed) like `:clean`, but set runMode + a cell-index boundary. A ShortcutKind tag is carried because PEG objects have no usable `==`.
  let rules = [(skShow, bareShowPattern, showimg), (skShowHtml, bareShowHtmlPattern, showimgHtml),
               (skClean, cleanPattern, clean), (skRunAll, runAllPattern, clean),
               (skRunAbove, runAbovePattern, clean), (skRunBelow, runBelowPattern, clean)]
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
          if kind == skShowHtml:
            # showhtml: always expands to HTML img tag (only for image files)
            if splitFile(matches[0]).ext in imageExt:
              replacement % matches
            else:
              # Non-image file: don't expand
              md.buf[][fragpos[0] .. fragpos[1]]
          elif kind == skShow and splitFile(matches[0]).ext notin imageExt:
            # Non-image bare `show:file`: emit an empty `show:` block `runCells` fills by streaming the file through its trim window.
            "```show:" & matches[0] & "\n```\n"
          else:
            # Image file with `show:`, or any other shortcut kind
            replacement % matches
        let deltaOffset = newvalue.len - (fragpos[1] - fragpos[0]) - 1
        md.buf[] = md.buf[][0 .. fragpos[0] - 1] & newvalue & md.buf[][fragpos[1] + 1 .. ^1]
        pos = (pos.first, pos.first + newvalue.len)
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, deltaOffset)
        startNextChunk += deltaOffset
        case kind
        of skClean: md.cleanBuild = true
        of skRunAll: md.runMode = rmAll
        # cell_i is the index of the first cell at/below this command line, so it is the above/below boundary; capturing the INDEX (not the byte offset) is robust to later offset shifts.
        of skRunAbove: md.runMode = rmAbove; md.runBoundaryAt = cell_i
        of skRunBelow: md.runMode = rmBelow; md.runBoundaryAt = cell_i
        else: discard
    endPrevChunk = startNextChunk

proc clearAllFiles(md: MarkdownFile) =
  var seen: HashSet[string]
  for cell in md.cells:
    if cell.properties.code:
      let source = cell.properties.source
      # Wipe ephemeral bare-block cache files and the signature sidecar too, so `:clean` re-runs every cell from a known-empty state.
      if source.len > 0 and source notin seen:
        seen.incl source
        source.tryRemoveFile
        sigSidecarPath(source).tryRemoveFile
      let output = cell.properties.output
      if output.len > 0: output.tryRemoveFile
