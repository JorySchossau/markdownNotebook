## Execution: build the shell command for a cell and run the dirty ones, writing
## their output to disk and back into `show:` cells. `buildCommand` handles `$1`
## substitution for compiled languages. Runs are **non-blocking**: a cell is
## launched with `osproc.startProcess` and reaped on a later watch cycle via
## `pollRuns`, so a long-running cell no longer blocks the watcher from parsing
## further saves (Tier 2 async item — see agents.md §8/§12). The `[ ]` state
## field (`s`/`r`/`x`/`k`) layers manual control on top of the dirty-driven
## auto-run default; existing notebooks keep working unchanged.
##
## Per-cell timeout (Tier 2): every launched cell is bounded by `timeout:N`
## seconds (default `defaultTimeout`, set in mdnb_types.nim). `pollRuns` checks
## each in-flight cell on every cycle and kills any that have exceeded their
## limit, writing a notice into the output file (and any matching `show:` cell)
## so the user sees what happened and why.

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

## ==============
## Non-blocking run state. The watch loop rebuilds a fresh `MarkdownFile` from
## disk on every save, so a running cell can't hold a pointer to the `md` it
## came from. Instead we keep just what's needed to (a) reap the process
## later and (b) write its captured output to disk under the cell's `output:`
## path; the matching `show:` cell is located in *whichever* `md` is current
## when the process finishes. Keyed by the source file path, which is unique
## per cell (auto-generated sources are unique per cell; explicit `source:`/
## `append:` targets are shared but a given running process still owns one).
type Running = object
  p: Process                 ## osproc handle; reaped non-blocking via peekExitCode
  filename: string           ## owning markdown file — reaps route back to its md
  language: string           ## runtime language id (for buildCommand lookup at start)
  sourceFile: string         ## the cell's source path — also our identity key
  outputFile: string         ## the cell's output: path — where captured stdout goes
  started: Time              ## when the cell was launched — for the per-cell timeout
  timeoutSecs: int           ## resolved per-cell timeout in seconds (default 5)

var running: seq[Running]    ## currently-executing cell subprocesses (module-global)

proc anyRunning(filename: string): bool =
  ## True if any in-flight cell belongs to `filename`. Used by the watch loop to
  ## decide whether a reap pass is warranted for a file that wasn't just saved.
  for r in running:
    if r.filename == filename: return true
  false

proc writeCellState(md: var MarkdownFile; idx: int; newState: char) =
  ## Splice a single new state char into this cell's `[x]` field in the info
  ## string (the fence line above the cell body). It's a 1-for-1 char swap so no
  ## downstream offset patching is needed. If the cell has no `[ ]` field (state
  ## was '\0'), there's nothing to write.
  if newState == '\0': return
  let cell = md.cells[idx]
  # `cell.rng.a` is the first body byte; the byte just before it is the `\n`
  # ending the info-string line. Scan back to that line's start (the previous
  # `\n`) and take the last `[` on it as the `[x]` field. We do NOT break on `]`
  # because we're scanning backwards and would hit the close-bracket first.
  var bracket = -1
  var i = cell.rng.a - 2
  while i >= 0 and md.buf[][i] != '\n':
    if md.buf[][i] == '[': bracket = i
    dec i
  if bracket == -1 or bracket + 2 >= md.buf[].len or md.buf[][bracket + 2] != ']':
    return # no `[ ]` field present on this cell
  md.buf[][bracket + 1] = newState
  md.write

proc showCellForOutput(md: MarkdownFile; outputFile: string): int =
  ## Index of the `show:` cell displaying `outputFile`, or -1 if none.
  for i, c in md.cells:
    if not c.properties.code and c.properties.show == outputFile:
      return i
  -1

proc cellShouldRun(cell: Cell): bool =
  ## Decide whether a code cell runs this pass under the layered `[ ]` model:
  ## dirty-driven auto-run stays the default (a cell with no `[ ]` or stopped
  ## states still runs when dirty); `[x]` forces a run even when clean; `s`
  ## stops a dirty cell from auto-running until the user marks it. `r`/`k` are
  ## mdnb-recognized control markers, never run triggers (`r` = already running,
  ## `k` = kill-requested, handled in pollRuns).
  if not cell.properties.code: return false
  case cell.properties.state
  of 's', 'r', 'k': return false        # stopped / running / kill-requested: don't (re)launch
  of 'x': return true                   # execute: force-run regardless of dirty
  else: return cell.properties.dirty    # '\0' default: today's dirty-driven behavior

proc startRun(md: var MarkdownFile; idx: int) =
  ## Launch one cell's process without blocking. Writes the source file, starts
  ## the subprocess (or writes output directly for `raw`), records it in
  ## `running`, and flips the cell's state `x` -> `r` in the file.
  let cell = md.cells[idx]
  let sourceFile = cell.properties.source
  let outputFile = cell.properties.output
  sourceFile.safeWriteFile(md.sources[sourceFile])
  let language = cell.properties.language
  if language == "raw":
    # raw blocks produce no subprocess; their body IS the output. Synchronous.
    md.sources[sourceFile].strip.safeWriteFile(outputFile)
    return
  let command = buildCommand(md.runtimes[language].command, sourceFile)
  # poEvalCommand routes the command through the shell (sh -c), matching how the
  # old blocking execProcess worked — so arbitrary shell commands, pipes, and
  # PATH lookups behave exactly as before. poStdErrToStdOut captures stderr into
  # the output too (the pre-async behavior via execProcess's default options).
  let p = startProcess(command, options = {poEvalCommand, poStdErrToStdOut})
  let secs = cell.properties.timeout
  running.add Running(p: p, filename: md.filename, language: language,
                      sourceFile: sourceFile, outputFile: outputFile,
                      started: getTime(), timeoutSecs: secs)
  if cell.properties.state == 'x':
    md.writeCellState(idx, 'r')         # x -> r so the user sees it flipped

proc reapFinished(md: var MarkdownFile; r: Running) =
  ## Read the finished process's stdout, write it to its `output:` file and
  ## into any `show:` cell of the current md, then flip the cell `r` -> `s`.
  var output = r.p.outputStream.readAll.strip
  r.p.close
  r.outputFile.safeWriteFile(output)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    md.writeIntoCell(showIdx, if output.len > 0: output else: "(empty output)")
    md.write
  # Flip the producing cell's state r -> s so the user sees it settled.
  for i, c in md.cells:
    if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
      md.writeCellState(i, 's')
      break

proc reapTimeout(md: var MarkdownFile; r: Running) =
  ## Kill a cell that exceeded its `timeout:` and write a notice explaining what
  ## happened and the limit that was hit, into both its `output:` file and any
  ## matching `show:` cell. Mirrors `reapFinished` but substitutes the notice for
  ## the (incomplete, possibly empty) captured output.
  osproc.kill(r.p)
  discard r.p.peekExitCode
  r.p.close
  let notice = &"(mdnb killed this cell: exceeded timeout:{r.timeoutSecs}s)"
  r.outputFile.safeWriteFile(notice)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    md.writeIntoCell(showIdx, notice)
    md.write
  for i, c in md.cells:
    if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
      md.writeCellState(i, 's')
      break

proc pollRuns(md: var MarkdownFile) =
  ## Reap finished/killed subprocesses belonging to `md.filename` non-blockingly.
  ## Called every watch cycle (independent of mtime change) so a long-running
  ## cell completing gets written back promptly. Also honors `[k]`: kill the
  ## matching running cell. Reaps are file-scoped so file A's slow cell never
  ## interferes with file B's cells.
  # First, honor kills: a cell now marked 'k' kills its running process.
  for i, cell in md.cells:
    if cell.properties.code and cell.properties.state == 'k':
      for j, r in running:
        if r.filename == md.filename and r.sourceFile == cell.properties.source:
          # osproc.kill sends SIGKILL (p.close only closes handles and leaves
          # the child orphaned/running). Reap the corpse, drop it from `running`,
          # and flip the cell's state k -> s — both on disk and in memory, so the
          # run-launch pass below doesn't immediately re-launch this cell.
          osproc.kill(running[j].p)
          discard running[j].p.peekExitCode
          running[j].p.close
          running.delete j
          md.cells[i].properties.state = 's'
          md.writeCellState(i, 's')
          break
  # Then reap whatever has finished on its own, or kill any past its timeout
  # (this file's processes only).
  let now = getTime()
  var i = 0
  while i < running.len:
    if running[i].filename != md.filename:
      inc i                              # belongs to another watched file
    elif now - running[i].started >= initDuration(seconds = running[i].timeoutSecs):
      # Per-cell timeout (Tier 2): exceeded its `timeout:N` (default 5s). Kill,
      # drop from `running`, and write a notice so the user can see what/why.
      md.reapTimeout(running[i])
      running.delete i
    elif running[i].p.peekExitCode == -1:
      inc i   # still running; leave it for a future cycle
    else:
      md.reapFinished(running[i])
      running.delete i

## ==============

proc runCells(md: var MarkdownFile) =
  ## Launch every cell that should run this pass (dirty, or `[x]`-forced) and
  ## reap any that finished since last cycle. Non-blocking: long cells are
  ## left in `running` and reaped on subsequent calls rather than blocking here.
  createDir "temp"
  md.pollRuns
  for i, cell in md.cells:
    if cellShouldRun(cell): md.startRun(i)
    elif not cell.properties.code:
      # Non-runnable `show:` cell: read its file back in if it already exists
      # (e.g. output landed on a previous pass, or from a prior session). This
      # mirrors the pre-async behavior. Cells whose producer is still running
      # get their freshest output on a later cycle via reapFinished.
      let target = cell.properties.show
      if fileExists(target):
        md.writeIntoCell(i, strip(readFile(target), chars = {' ', '\n'}))
        md.write
