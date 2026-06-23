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
    let cellid = md.cells.len + 1
    var (props, invalid) = parseCellCommands(matches, md)
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
