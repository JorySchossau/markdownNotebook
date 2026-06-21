## Shortcut expansion and clean build. `replaceShortcuts` rewrites bare
## `show:file` text (to an image link or a `show:` block) and `:clean` lines,
## running in the gaps between already-parsed cells; `clearAllFiles` is the
## `:clean` handler that deletes every generated source/output file.
proc replaceShortcuts(md: var MarkdownFile) =
  var pos: tuple[first, last: int]
  var endPrevChunk, startNextChunk = 0
  var matches = newSeq[string](1)
  let (showimg, clean, showtxt) = ("![$1]($1)\n", "", "```show:$1\n$2\n```\n")
  for cell_i in 0 .. md.cells.len:
    startNextChunk = if cell_i == md.cells.len: md.buf[].len - 1
                     else: md.cells[cell_i].rng.a
    for pattern, replacement in [(bareShowPattern, showimg), (cleanPattern, clean)].items:
      pos = (-1, 0)
      while true:
        matches[0] = ""
        pos = md.buf[][endPrevChunk .. startNextChunk].findBounds(pattern, matches, start = pos.last)
        if pos.first == -1: break
        let fragpos = (endPrevChunk + pos.first + 1, endPrevChunk + pos.last)
        var newvalue: string
        if replacement == clean or (replacement == showimg and splitFile(matches[0]).ext in imageExt):
          newvalue = replacement % matches
        else:
          let contents = if fileExists(matches[0]): readFile(matches[0]) else: "```show:$1\n```\n"
          newvalue = showtxt % [matches[0], contents]
        let deltaOffset = newvalue.len - (fragpos[1] - fragpos[0]) - 1
        md.buf[] = md.buf[][0 .. fragpos[0] - 1] & newvalue & md.buf[][fragpos[1] + 1 .. ^1]
        pos = (pos.first, pos.first + newvalue.len)
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, deltaOffset)
        startNextChunk += deltaOffset
        if replacement == clean: md.cleanBuild = true
    endPrevChunk = startNextChunk

proc clearAllFiles(md: MarkdownFile) =
  var seen: HashSet[string]
  for cell in md.cells:
    if cell.properties.code:
      let source = cell.properties.source
      if source notin seen:
        seen.incl source
        removeFile(source)
      removeFile(cell.properties.output)
