import std/[strutils, sequtils, options, pegs, tables, os, strformat, osproc, times]

## ==============
const imageExt = "png jpg jpeg gif pdf".split().mapIt("." & it)
let
  yamlEndPattern = peg"""\n'---' '-'*\n"""
  yamlConfigPattern =
    peg"""
    r <- \n \s* 'code' \s* ':' \s* {mdlangid} \s* {langext} \s* runcmd
    mdlangid <- \w*
    langext <- (\w  /  '.')*
    runcmd <- quoted_cmd  /  unquoted_cmd
    quoted_cmd <- \" {(CommandChars  /  \s)*} \"
    unquoted_cmd <- {CommandChars*}
    CommandChars <- !\n !\" \w  /  '.'  /  ':'  /  '-'  /  '/'  /  '\\'
    """
  chunkPattern =
    peg"""
    r <- (\n / ^) upTo3WS {codefence} (!\n \s* {command})+ (!codefenceend .)* codefenceend
    codefence <- "```" '`'* / "~~~" '~'*
    upTo3WS <- !\n \s? !\n \s? !\n \s?
    command <- word ':' quoted_string   /   word ':' word   /   word
    quoted_string <- \" ( !\" .)+ \"
    word <- (\w / \/ / \\ / \. / \-)+
    codefenceend <- \n upTo3WS $1 (!\n \s)* \n
    """
  bareShowPattern = peg"""\n (!\n \s)* "show:" {(\w / '.' / '-' / ':' / '/' / '\\')*} (!\n \s)* \n"""
  cleanPattern = peg"""\n ":clean" (!\n \s)* \n"""
## ==============

proc safeWriteFile(filename, contents: string) =
  var error = true
  while error:
    try:
      writeFile(filename, contents)
      error = false
    except CatchableError:
      discard

## ==============

type CellProperties = object
  dirty: bool
  code: bool
  language, header, output, source, show: Option[string]

type Cell = object
  id: int
  rng: HSlice[int, int]
  properties: CellProperties

type Runtime = object
  command: string
  extension: string

type MarkdownFile = object
  filename: string
  buf: ref string
  cells: seq[Cell]
  runtimes: Table[string, Runtime]
  sources: Table[string, string]
  cellsWritingToSource: Table[string, int]
  cleanBuild: bool

## ==============

proc content(md: MarkdownFile; cell: Cell): string = md.buf[][cell.rng]

## ==============

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

proc addCell(md: var MarkdownFile; rng: HSlice[int, int]; properties = CellProperties()) =
  md.cells.add Cell(id: md.cells.len + 1, rng: rng, properties: properties)

proc processBodyForCells(md: var MarkdownFile) =
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
      let command = match.split(':')
      case command[0]
      of "source":
        props.code = true
        if command.len == 2: props.source = some(command[1])
      of "output", "show", "header":
        if command.len != 2:
          echo "Skipping cell: argument required: 'command:argument'"
          invalid = true
        case command[0]
        of "output":
          props.code = true
          props.output = some(command[1])
        of "show": props.show = some(command[1])
        of "header": props.header = some(command[1])
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

proc newMarkdownFile(filename: string): MarkdownFile =
  result.filename = filename
  result.buf = new(string)
  result.buf[] = readFile(filename)

proc updatePositionsByOffset(md: var MarkdownFile; cellposition, fileoffset: int) =
  for i in cellposition ..< md.cells.len:
    md.cells[i].rng.a += fileoffset
    md.cells[i].rng.b += fileoffset

proc writeIntoCell(md: var MarkdownFile; idx: int; value: string) =
  let cell = md.cells[idx].addr
  md.buf[] = md.buf[][0 .. cell.rng.a - 1] & value & '\n' & md.buf[][cell.rng.b + 1 .. ^1]
  let deltaOffset = value.len + 1 - (cell.rng.b - cell.rng.a + 1)
  cell.rng.b = cell.rng.a + value.len
  md.updatePositionsByOffset(cell.id, deltaOffset)

proc collateSources(md: var MarkdownFile) =
  for cell in md.cells:
    if not cell.properties.code: continue
    let source = cell.properties.source.get
    if source notin md.sources: md.sources[source] = ""
    md.sources[source] &= md.content(cell) & '\n'
    md.cellsWritingToSource[source] = md.cellsWritingToSource.getOrDefault(source) + 1

proc markDirtyCells(md: var MarkdownFile) =
  for i in 0 ..< md.cells.len:
    if not md.cells[i].properties.code: continue
    let source = md.cells[i].properties.source.get
    let output = md.cells[i].properties.output.get
    if not fileExists(source) or not fileExists(output):
      md.cells[i].properties.dirty = true
    elif readFile(source) != md.sources[source]:
      md.cells[i].properties.dirty = true

proc write(md: MarkdownFile) = md.filename.safeWriteFile(md.buf[])

proc showWaitMessages(md: var MarkdownFile) =
  for codeCell in md.cells:
    if not (codeCell.properties.code or codeCell.properties.dirty): continue
    for i, showCell in md.cells:
      if showCell.properties.code: continue
      if showCell.properties.show == codeCell.properties.output:
        md.writeIntoCell(i, "(please wait)")
  md.write

proc runCells(md: var MarkdownFile) =
  createDir "temp"
  for i, cell in md.cells:
    if cell.properties.dirty:
      let sourceFilename = cell.properties.source.get
      let outFilename = cell.properties.output.get
      sourceFilename.safeWriteFile(md.sources[sourceFilename])
      let language = cell.properties.language.get
      if language != "raw":
        let command = md.runtimes[language].command & ' ' & sourceFilename
        outFilename.safeWriteFile(strip(execProcess(command)))
    elif not cell.properties.code:
      let target = cell.properties.show.get
      if fileExists(target):
        md.writeIntoCell(i, strip(readFile(target), chars = {' ', '\n'}))
        md.write

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
  for cell in md.cells:
    if cell.properties.code:
      removeFile(cell.properties.source.get)
      removeFile(cell.properties.output.get)

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

## ==============

proc getLastModTime(filename: string): Time =
  var error = true
  while error:
    try:
      result = getLastModificationTime(filename)
      error = false
    except OSError:
      discard

proc main =
  var params = commandLineParams()
  var looping = true
  if params.anyIt(it == "-o"):
    looping = false
    params.keepItIf(it != "-o")

  if params.len == 0 or not params.allIt(fileExists(it)):
    echo "Error: specify markdown filename(s) and optionally -o for run once"
    quit()

  var modTimes = newSeq[Time](params.len)
  for idx, filename in params:
    modTimes[idx] = if looping: getLastModTime(filename)
                    else: getLastModTime(filename) - 1.minutes

  echo "started"
  while true:
    for idx, filename in params:
      if modTimes[idx] < getLastModTime(filename):
        var md = newMarkdownFile(filename)
        if not looping: md.cleanBuild = true
        md.process
        modTimes[idx] = getLastModTime(filename)
    if looping: sleep(500)
    else: break

## ==============

when isMainModule:
  main()
