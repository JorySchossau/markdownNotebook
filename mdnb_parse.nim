## Parsing: turn the markdown buffer into cells. `processYamlHeader` reads the
## `code:` runtimes from frontmatter; `processBodyForCells` PEG-scans fenced
## blocks into `Cell`s, with a content-keyed cache so a byte-identical buffer
## (an editor auto-save, or a no-op re-save of mdnb's own output) skips the scan.
## See agents.md §4 / §6.
proc processYamlHeader(md: var MarkdownFile) =
  if md.buf[].len > 3 and md.buf[][0 .. 2] == "---":
    var matches = newSeq[string](3)
    let endOfYaml = md.buf[].find(yamlEndPattern)
    if endOfYaml == -1: return
    let header = md.buf[][0 .. endOfYaml]
    var pos: tuple[first, last: int] = (-1, -1)
    while true:
      pos = header.findBounds(yamlConfigPattern, matches, start = pos.last + 1)
      if pos.first == -1: break
      md.runtimes[matches[0]] = Runtime(extension: matches[1], command: matches[2])

## Position cache: maps file content -> parsed cells. The content itself is the
## cache key, so a byte-identical buffer (e.g. an editor auto-save of mdnb's own
## output, or a no-op re-save) hits the cache and skips the PEG scan entirely;
## any real edit changes the key and falls back to a full re-parse. Entries hold
## onto a copy of their key, so cap the size to keep memory bounded.
const cellCacheMax = 32
var cellCache: OrderedTable[string, seq[Cell]]

proc addCell(md: var MarkdownFile; rng: HSlice[int, int]; properties = CellProperties()) =
  md.cells.add Cell(id: md.cells.len + 1, rng: rng, properties: properties)

proc processBodyForCells(md: var MarkdownFile) =
  ## Populate `md.cells` from the fenced code blocks in `md.buf`. Reuses cached
  ## cell positions when the buffer is byte-identical to a previous parse (the
  ## content itself is the cache key, so any edit invalidates automatically);
  ## otherwise runs the full PEG scan and stores the result for next time.
  if md.buf[] in cellCache:
    md.cells = cellCache[md.buf[]]
    return
  md.cells.setLen 0
  var matches = newSeq[string](16)
  var pos: tuple[first, last: int] = (-1, -1)
  let buf = md.buf
  while true:
    for match in matches.mitems: match = ""
    pos = buf[].findBounds(chunkPattern, matches, start = pos.last + 1)
    if pos.first == -1: break
    var props: CellProperties
    let cellid = md.cells.len + 1
    var invalid = false
    for i, match in matches:
      if i == 0: continue
      if match.len == 0: break
      if i == 1 and (match in md.runtimes or match == "raw"):
        props.language = some(match)
      # `[ ]` state field: a single-char token wrapped in brackets (states
      # s/r/x/k). The grammar only emits valid states (see stateField), so an
      # unrecognized bracketed token means the user mistyped and the cell is
      # skipped, matching how other malformed commands are handled.
      if match.len == 3 and match[0] == '[' and match[2] == ']':
        let st = match[1]
        if st in "srxk": props.state = st
        else:
          echo &"Skipping cell: invalid state '{st}' (expected s/r/x/k)"
          invalid = true
        continue
      let command = match.split(':')
      case command[0]
      of "source":
        if props.isAppend:
          echo "Skipping cell: 'source:' and 'append:' are mutually exclusive"
          invalid = true
        else:
          props.code = true
          if command.len == 2: props.source = some(command[1])
      of "append":
        if props.source.isSome:
          echo "Skipping cell: 'source:' and 'append:' are mutually exclusive"
          invalid = true
        elif command.len != 2:
          echo "Skipping cell: argument required: 'append:filename'"
          invalid = true
        else:
          props.code = true
          props.isAppend = true
          props.source = some(command[1])
      of "output", "show", "inputs":
        if command.len != 2:
          echo "Skipping cell: argument required: 'command:argument'"
          invalid = true
        case command[0]
        of "output":
          props.code = true
          props.output = some(command[1])
        of "show": props.show = some(command[1])
        of "inputs": props.inputs = command[1].split(',')
        else: discard
      else: discard
    if props.code and props.language.isNone: invalid = true
    if invalid: continue
    if props.code and props.source.isNone:
      props.source = some("temp" / &"{splitFile(md.filename).name}_src{cellid}{md.runtimes[props.language.get].extension}")
    if props.code and props.output.isNone:
      props.output = some("temp" / &"{splitFile(md.filename).name}_src{cellid}.txt")
    let contentStart = buf[].find(chars = {'\n'}, start = pos.first + 2)
    var contentEnd = buf[].rfind(chars = {'\n'}, last = pos.last - 1)
    if contentEnd <= contentStart: contentEnd = contentStart
    md.addCell(contentStart + 1 .. contentEnd, props)
  if cellCache.len >= cellCacheMax:
    var stale: seq[Cell]
    discard cellCache.pop(toSeq(cellCache.keys)[0], stale)
  cellCache[md.buf[]] = md.cells

proc newMarkdownFile(filename: string): MarkdownFile =
  result.filename = filename
  result.buf = new(string)
  result.buf[] = readFile(filename)
