## Execution: build the shell command for a cell and run the dirty ones, writing
## their output to disk and back into `show:` cells. `buildCommand` handles `$1`
## substitution for compiled languages; `runCells` is the actual exec layer.
proc buildCommand(command, sourceFilename: string): string =
  ## Build the shell command for a cell. If `command` contains `$1`, every
  ## occurrence is replaced by `sourceFilename` with its extension stripped
  ## (e.g. `temp/demo_src1.cpp` -> `temp/demo_src1`), so compiled-language
  ## commands like `g++ -o $1.out $1.cpp && ./$1.out` work. Otherwise the
  ## source filename is appended to the command, as before.
  if "$1" in command:
    let (dir, name, _) = sourceFilename.splitFile
    command.replace("$1", dir / name)
  else:
    command & ' ' & sourceFilename

proc runCells(md: var MarkdownFile) =
  createDir "temp"
  for i, cell in md.cells:
    if cell.properties.dirty:
      let sourceFilename = cell.properties.source.get
      let outFilename = cell.properties.output.get
      sourceFilename.safeWriteFile(md.sources[sourceFilename])
      let language = cell.properties.language.get
      if language != "raw":
        let command = buildCommand(md.runtimes[language].command, sourceFilename)
        outFilename.safeWriteFile(strip(execProcess(command)))
    elif not cell.properties.code:
      let target = cell.properties.show.get
      if fileExists(target):
        md.writeIntoCell(i, strip(readFile(target), chars = {' ', '\n'}))
        md.write
