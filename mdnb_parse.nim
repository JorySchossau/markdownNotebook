## Parsing: `processYamlHeader` reads the `code:` runtimes; `processBodyForCells` PEG-scans fenced blocks into `Cell`s, with a content-keyed cache (agents.md §4/§6).
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

## Position cache: file content -> parsed cells. Content is the key, so a byte-identical buffer hits the cache (skipping the scan) and any edit falls back to a full re-parse. Capped at 32 entries.
const cellCacheMax = 32
var cellCache: OrderedTable[string, seq[Cell]]

proc addCell(md: var MarkdownFile; rng: HSlice[int, int]; properties = CellProperties()) =
  md.cells.add Cell(id: md.cells.len + 1, rng: rng, properties: properties)

proc processBodyForCells(md: var MarkdownFile) =
  ## Populate `md.cells` from fenced blocks, reusing cached positions when the buffer is byte-identical to a previous parse.
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
        props.language = match
      # `[ ]` state field: `[`+one of s/r/x/k+`]`. An unrecognized bracketed token means a mistype -> skip the cell.
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
          if command.len == 2: props.source = command[1]
      of "append":
        if props.source.len > 0:
          echo "Skipping cell: 'source:' and 'append:' are mutually exclusive"
          invalid = true
        elif command.len != 2:
          echo "Skipping cell: argument required: 'append:filename'"
          invalid = true
        else:
          props.code = true
          props.isAppend = true
          props.source = command[1]
      of "output", "show", "inputs":
        # Guard the arg access behind `else` (mirroring `append`): a bare `output`/`show`/`inputs` with no `:arg` has len 1, so `command[1]` would IndexDefect without this branch.
        if command.len != 2:
          echo "Skipping cell: argument required: 'command:argument'"
          invalid = true
        else:
          case command[0]
          of "output":
            props.code = true
            props.output = command[1]
          of "show": props.show = command[1]
          of "inputs": props.inputs = command[1].split(',')
          else: discard
      of "timeout":
        if command.len != 2:
          echo "Skipping cell: argument required: 'timeout:N' (seconds)"
          invalid = true
        else:
          try: props.timeout = parseInt(command[1])
          except ValueError:
            echo &"Skipping cell: 'timeout:N' expects an integer, got '{command[1]}'"
            invalid = true
      of "trim":
        # `trim:head,N` / `trim:tail,N` (comma-separated, no spaces) — parses under the existing `word ':' word` grammar like `inputs:a,b,c`.
        if command.len != 2:
          echo "Skipping cell: argument required: 'trim:head,N' / 'trim:tail,N'"
          invalid = true
        else:
          let parts = command[1].split(',')
          if parts.len != 2 or parts[0] notin ["head", "tail"]:
            echo &"Skipping cell: 'trim' wants head,N or tail,N, got '{command[1]}'"
            invalid = true
          else:
            try:
              let n = parseInt(parts[1])
              if n <= 0: raise newException(ValueError, "non-positive")
              props.trimTail = parts[0] == "tail"
              props.trimLines = n
            except ValueError:
              echo &"Skipping cell: 'trim' count expects a positive integer, got '{parts[1]}'"
              invalid = true
      else: discard
    # Resolve optional defaults so the execution layer can read them unconditionally.
    if props.timeout == 0: props.timeout = defaultTimeout
    if props.trimLines == 0: props.trimLines = defaultTrimLines
    # A bare language-fence (registered language, no command) is an ephemeral cell: runs a content-hash-named tmp source for side effects; no output kept; cache in the filename (see markDirtyCells/sweepEphemeralCache).
    if not props.code and props.language.len > 0 and props.language in md.runtimes:
      props.code = true
      props.ephemeral = true
    if props.code and props.language.len == 0: invalid = true
    if invalid: continue
    elif props.code and props.source.len == 0:
      props.source = "temp" / &"{splitFile(md.filename).name}_src{cellid}{md.runtimes[props.language].extension}"
    # Ephemeral cells keep no output; other runnable cells without an explicit `output:` get the default txt path.
    if props.code and not props.ephemeral and props.output.len == 0:
      props.output = "temp" / &"{splitFile(md.filename).name}_src{cellid}.txt"
    let contentStart = buf[].find(chars = {'\n'}, start = pos.first + 2)
    var contentEnd = buf[].rfind(chars = {'\n'}, last = pos.last - 1)
    if contentEnd <= contentStart: contentEnd = contentStart
    if props.ephemeral:
      # Tmp name in the cwd encoding a hash of body + command signature (no cell id), so a cell's cache identity is its content+config, not its position. Editing body/config -> new filename -> orphan (swept next run) -> missing -> dirty -> runs.
      let body = md.buf[][contentStart + 1 .. contentEnd]
      let h = contentHash(body & "\x00" & props.cellSignature)
      let base = splitFile(md.filename).name & "_tmp_" & h
      props.source = base & md.runtimes[props.language].extension
    md.addCell(contentStart + 1 .. contentEnd, props)
  if cellCache.len >= cellCacheMax:
    var stale: seq[Cell]
    discard cellCache.pop(toSeq(cellCache.keys)[0], stale)
  cellCache[md.buf[]] = md.cells

proc newMarkdownFile(filename: string): MarkdownFile =
  result.filename = filename
  result.buf = new(string)
  result.buf[] = readFile(filename)
