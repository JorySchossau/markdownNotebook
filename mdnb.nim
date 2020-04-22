import strutils, sequtils, options, pegs, tables, os, strformat, std/decls, osproc, times

## ==============

let
  yamlEndPattern =
    peg"""\n'---' '-'*\n"""
  # ex: code: sh .sh "bash -c"
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
  # ex: (one entire markdown codefenced chunk, commonmark specification)
  chunkPattern =
    peg"""
    r <- (\n / ^) upTo3WS {codefence} (!\n \s* {command})+ (!codefenceend .)* codefenceend
    codefence <- "```" '`'* / "~~~" '~'*
    upTo3WS <- \s? \s? \s?
    command <- word ':' quoted_string   /   word ':' word   /   word
    quoted_string <- \" ( !\" .)+ \"
    word <- (\w / \/ / \\ / \. / \-)+
    codefenceend <- \n upTo3WS $1 (!\n \s)* \n
    """
  # ex: show:afile.png (not in a code chunk), replace with url or code chunk if non-img
  bareShowPattern = peg"""\n (!\n \s)* "show:" {(\w / '.' / '-' / ':' / '/' / '\\')*} (!\n \s)* \n"""
  # ex: :clean
  cleanPattern = peg"""\n ":clean" (!\n \s)* \n"""
## ==============

proc safeWriteFile(filename,contents:string) =
  var error = true
  # assume there will/was an error
  while error:
    try:
      filename.write_file contents
      # only set flag false on success
      error = false
    except:
      discard

proc safeReadFile(filename:string):string =
  var error = true
  # assume there will/was an error
  while error:
    try:
      result = read_file filename
      # only set flag false on success
      error = false
    except:
      discard

## ==============

type CellProperties = object
  dirty:bool
  code:bool # indicates runnable (source or output defined)
  language, header, output, source, show:Option[string]

type Cell = object
  id:int
  rng:HSlice[int,int]
  privContent:ptr ptr string
  properties:CellProperties

type Runtime = object
  command:string
  extension:string

type MarkdownFile = object
  filename:string
  privContent:ptr ptr string
  cells: seq[Cell]
  runtimes:Table[string,Runtime]
  sources:Table[string,string]
  cellsWritingToSource:Table[string,int] # how many cells have yet to write to `string` source file
  cleanBuild:bool # remove all files

## ==============

proc content(cell:Cell):string = cell.privContent[][][cell.rng]

## ==============

proc processYamlHeader(md:var MarkdownFile) =
  if md.privContent[][].len > 3 and md.privContent[][][0 .. 2] == "---":
    var matches = newSeq[string](3)
    let endOfYaml = md.privContent[][].find(yamlEndPattern)
    if endOfYaml == -1: return # no end of header found, so assume none
    let header = md.privContent[][][0..endOfYaml]
    var pos:tuple[first,last:int] = (-1, -1)
    while true:
      pos = header.findBounds(yamlConfigPattern,matches,start=pos.last+1)
      if pos.first == -1: break # done finding lang configs
      md.runtimes[matches[0]] = Runtime(extension:matches[1], command:matches[2])

proc addCell(md:var MarkdownFile, rng:HSlice[int,int], properties:CellProperties=CellProperties()):Cell {.discardable.} =
  result.rng = rng
  result.privContent = md.privContent
  result.properties = properties
  result.id = md.cells.len + 1
  md.cells.add result

proc processBodyForCells(md:var MarkdownFile) =
  var matches = newSeq[string](16)
  var pos:tuple[first,last:int] = (-1, -1)
  let content {.byAddr.} = md.privContent[][]
  while true:
    for match in matches.mitems: match = "" # reset matches
    pos = content.findBounds(chunkPattern,matches,start=pos.last+1)
    if pos.first == -1: break # done finding code chunks
    var props:CellProperties
    let cellid = md.cells.len+1
    var invalid = false
    for i,match in matches:
      if i==0: continue # skip fence match (```)
      if match.len == 0: break # pegs module returns 20 matches, always; skip blanks
      # store language
      if i==1 and (match in md.runtimes or match == "raw"):
        props.language = some(match)
      # store commands
      let command = match.split(':')
      case command[0]
        of "source":
          props.code = true
          if command.len == 2: props.source = some(command[1])
        of "output","show","header":
          if command.len != 2:
            echo "Skipping cell: argument required: 'command:argument'"
            invalid = true
          case command[0]:
            of "output":
              props.code = true
              props.output = some(command[1])
            of "show": props.show = some(command[1])
            of "header": props.header = some(command[1])
            else: discard
        else: discard
    if (props.code) and props.language.isNone: invalid = true
    if invalid: continue
    # autogenerate source if necessary, otherwise accept user's arg
    if props.code and props.source.isNone: props.source = some("temp" / &"{md.filename.split_file.name}_src{$cellid}{md.runtimes[props.language.get].extension}")
    # create temp output if none specified
    if props.code and props.output.isNone:
      props.output = some("temp" / &"{md.filename.split_file.name}_src{$cellid}.txt")
    # find actual content range
    var content_start = content.find(chars={'\n'},start=pos.first+2)
    var content_end = content.rfind(chars={'\n'},last=pos.last-1)
    if (content_end <= content_start): content_end = content_start
    md.addCell(rng=content_start+1 .. content_end, properties=props)

proc newMarkdownFile(filename:string):MarkdownFile =
  let contents = read_file filename
  result.filename = filename
  result.privContent = createU(ptr string, 1)
  result.privContent[] = string.createU(contents.len)
  result.privContent[][] = contents
  result.processYamlHeader
  result.processBodyForCells

proc content(md:MarkdownFile):string = md.privContent[][]

proc updatePositionsByOffset(md:var MarkdownFile, cellposition:int, fileoffset:int) =
  for id in cellposition ..< md.cells.len:
    md.cells[id].rng.a += fileoffset
    md.cells[id].rng.b += fileoffset

proc writeIntoCell(md:var MarkdownFile, cell:var Cell, value:string) =
  var txt {.byAddr.} = cell.privContent[][]
  txt = txt[0..cell.rng.a-1] & value & '\n' & txt[cell.rng.b+1..^1]
  let deltaOffset = value.len + 1 - (cell.rng.b-cell.rng.a+1)
  cell.rng.b = cell.rng.a + value.len # FIXME - 1
  md.updatePositionsByOffset(cellposition=cell.id, fileoffset=deltaOffset)

proc collateSources(md:var MarkdownFile) =
  for cell in md.cells.mitems:
    if not cell.properties.code: continue
    discard md.sources.hasKeyOrPut(cell.properties.source.get, "")
    md.sources[cell.properties.source.get] &= cell.content & '\n'
    discard md.cellsWritingToSource.hasKeyOrPut(cell.properties.source.get, 0)
    inc md.cellsWritingToSource[cell.properties.source.get]

proc markDirtyCells(md:var MarkdownFile) =
  for cell in md.cells.mitems:
    if not cell.properties.code: continue
    if not existsFile cell.properties.source.get: cell.properties.dirty = true
    if not existsFile cell.properties.output.get: cell.properties.dirty = true
    if existsFile cell.properties.source.get:
      let oldsource = readfile cell.properties.source.get
      if oldsource != md.sources[cell.properties.source.get]: cell.properties.dirty = true

proc write(md:var MarkdownFile) = md.filename.safeWriteFile md.content

proc showWaitMessages(md:var MarkdownFile) =
  for codeCell in md.cells.mitems:
    if (not codeCell.properties.code) and (not codeCell.properties.dirty): continue
    for showCell in md.cells.mitems:
      if showCell.properties.code: continue
      if showCell.properties.show == codeCell.properties.output:
        md.writeIntoCell(showCell, "(please wait)")
  md.write

proc runCells(md:var MarkdownFile) =
  createDir "temp"
  for cell in md.cells.mitems:
    if cell.properties.dirty:
      let sourceFilename = cell.properties.source.get
      let outFilename = cell.properties.output.get
      sourceFilename.safeWriteFile(md.sources[sourceFilename])
      let language = cell.properties.language.get
      if language != "raw":
        let command = md.runtimes[language].command & ' ' & sourceFilename
        let cmdresult = execProcess(command)
        outFilename.safeWriteFile(strip cmdresult)
    elif not cell.properties.code: # show-ing cell
      if existsFile cell.properties.show.get:
        let contents = safeReadFile cell.properties.show.get
        md.writeIntoCell(cell, strip(contents,chars={' ','\n'}))
        md.write # write after every output (todo: don't if little time has passed)

proc replaceShortcuts(md:var MarkdownFile) =
  var txt {.byAddr.} = md.privContent[][]
  var pos:tuple[first,last:int]
  var endPrevChunk, startNextChunk:int
  endPrevChunk = 0
  var matches = newSeq[string](1)
  for cell in md.cells.mitems:
    pos = (-1,0)
    startNextChunk = cell.rng.a
    while true:
      matches[0] = ""
      pos = md.privContent[][][endPrevChunk..startNextChunk].findBounds(bareShowPattern, matches, start=pos.last)
      if pos.first == -1: break
      let fragpos = (endPrevChunk+pos.first + 1, endPrevChunk+pos.last)
      let newvalue = &"![{matches[0]}]({matches[0]})\n"
      let deltaOffset = newvalue.len - (fragpos[1]-fragpos[0]) - 1
      txt = txt[0..fragpos[0]-1] & newvalue & txt[fragpos[1]+1..^1]
      pos = (pos.first, pos.first+newvalue.len)
      md.updatePositionsByOffset(cellposition=cell.id-1, fileoffset=deltaOffset)
      startNextChunk += deltaOffset
    pos = (-1,0)
    while true:
      matches[0] = ""
      pos = md.privContent[][][endPrevChunk..startNextChunk].findBounds(cleanPattern, matches, start=pos.last)
      if pos.first == -1: break
      let fragpos = (endPrevChunk+pos.first + 1, endPrevChunk+pos.last)
      txt = txt[0..fragpos[0]-1] & txt[fragpos[1]+1..^1] # completely remove fragment
      pos = (pos.first, pos.last-7)
      md.updatePositionsByOffset(cellposition=cell.id-1, fileoffset= -7)
      startNextChunk += -7
      md.cleanBuild = true
    endPrevChunk = cell.rng.b
  pos = (-1,0)
  startNextChunk = md.privContent[][].len-1
  while true:
    matches[0] = ""
    pos = md.privContent[][][endPrevChunk..startNextChunk].findBounds(bareShowPattern, matches, start=pos.last)
    if pos.first == -1: break
    let fragpos = (endPrevChunk+pos.first + 1, endPrevChunk+pos.last)
    let newvalue = &"![{matches[0]}]({matches[0]})\n"
    let deltaOffset = newvalue.len - (fragpos[1]-fragpos[0]) - 1
    txt = txt[0..fragpos[0]-1] & newvalue & txt[fragpos[1]+1..^1]
    pos = (pos.first, pos.first+newvalue.len)
    startNextChunk += deltaOffset
  pos = (-1,0)
  while true:
    matches[0] = ""
    pos = md.privContent[][][endPrevChunk..startNextChunk].findBounds(cleanPattern, matches, start=pos.last)
    if pos.first == -1: break
    let fragpos = (endPrevChunk+pos.first + 1, endPrevChunk+pos.last)
    txt = txt[0..fragpos[0]-1] & txt[fragpos[1]+1..^1] # completely remove fragment
    pos = (pos.first, pos.last-7)
    startNextChunk += -7
    md.cleanBuild = true

proc clearAllFiles(md:var MarkdownFile) =
  for codeCell in md.cells.filterIt(it.properties.code):
    removeFile codeCell.properties.source.get
    removeFile codeCell.properties.output.get

proc process(md:var MarkdownFile) =
  md.replaceShortcuts
  if md.cleanBuild:
    md.clearAllFiles
    md.cleanBuild = false
  md.collateSources
  md.markDirtyCells
  md.showWaitMessages
  md.runCells
  md.write

## ==============

proc getLastModTime(filename:string):Time =
  var error = true
  # assume there will/was an error
  while error:
    try:
      result = getLastModificationTime filename
      # only set flag false on success
      error = false
    except OSError:
      discard

proc main =
  var params = commandLineParams()

  # check if running once
  var looping = true
  if params.anyIt(it == "-o"):
    looping = false
    params.keepItIf(it != "-o")

  # safety first
  if params.len == 0 or not params.allIt(exists_file it):
    echo "Error: specify markdown filename(s) and optionally -o for run once"
    quit()

  # set up initial filewatch structures
  let filenames {.byAddr.} = params
  var modTimes = newSeq[Time](len params)
  for idx,filename in filenames:
    if not looping: modTimes[idx] = getLastModTime(filename)-1.minutes
    else:           modTimes[idx] = getLastModTime(filename)

  # file watch loop (runs only once if -o passed)
  var noneModified = true
  echo "started"
  while true:
    for idx,filename in filenames:
      if modTimes[idx] < getLastModTime(filename):
        var md = newMarkdownFile filename
        if not looping: md.cleanBuild = true
        md.process
        modTimes[idx] = getLastModTime(filename)
    if looping: sleep 500
    else: break

## ==============

when isMainModule:
  main()
