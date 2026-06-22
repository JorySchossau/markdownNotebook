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
##
## Pipe draining (Tier 2): a cell's stdout reaches mdnb through an OS pipe whose
## buffer is tiny (~64KB). If we only read it after the process exits (the old
## behavior), any cell whose output exceeds the buffer fills it and the producer
## then *blocks* writing to a full pipe — it can never exit, so the read never
## happens, so the cell hangs until its `timeout:` kills it. `pollRuns` now
## drains each running cell's pipe on *every* cycle (`drainOutput`) into a
## per-cell accumulator, so the producer is never blocked. `readData` returns 0
## the instant the pipe is momentarily empty (it does not block on a live pipe),
## so the drain is a cheap non-blocking spin that fits the existing poll cadence;
## the accumulated output is trimmed/written on the cycle the process exits.


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
  ephemeral: bool            ## bare-block cell: cwd tmp source kept as a cache, no output kept
  started: Time              ## when the cell was launched — for the per-cell timeout
  timeoutSecs: int           ## resolved per-cell timeout in seconds (default 5)
  cellId: int                ## 1-based cell ordinal at launch — for verbose status
  command: string            ## resolved shell command that ran — for verbose status
  acc: string                ## drained-so-far stdout; pipe buffer is ~64KB, so a cell
                             ## whose output exceeds it would block forever writing to a
                             ## full pipe if we only read on exit (see drainOutput).

var running: seq[Running]    ## currently-executing cell subprocesses (module-global)
var verbose: bool            ## set by `-v`/`--verbose`; gates per-run status logging

proc logRunStatus(r: Running; exitCode: int; note = "") =
  ## Verbose execution status (Tier 3): one line per completed cell run to stdout
  ## — cell id, the resolved command, exit code, and wall-clock duration. Gated on
  ## the `-v`/`--verbose` flag (set in `main`) so the default run stays quiet
  ## ("pure addition, no behavior change"). Called from every reap path: normal
  ## finish, timeout-kill, and manual `[k]`-kill. For killed cells `note` carries
  ## the reason (a post-SIGKILL `peekExitCode` is unreliable, often -1), so we
  ## print that in place of the exit code.
  if not verbose: return
  let dur = (getTime() - r.started).inMicroseconds.float / 1_000_000.0
  let tail = if note.len > 0: note else: "exit " & $exitCode
  echo &"[mdnb] {r.filename} cell {r.cellId}: '{r.command}' -> {tail} in {dur:.3f}s"

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

proc cellWithSource(md: MarkdownFile; sourceFile: string): CellProperties =
  ## The `CellProperties` of the code cell that writes `sourceFile`. Used to find
  ## the `trim:` settings that should govern a `show:` cell's display of that
  ## cell's output — the producer carries the trim window so the show block
  ## doesn't have to redeclare it. Returns a default (head,50) if not found.
  for c in md.cells:
    if c.properties.code and c.properties.source == sourceFile:
      return c.properties
  CellProperties(trimLines: defaultTrimLines)

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
  let ephemeral = cell.properties.ephemeral
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
                      ephemeral: ephemeral,
                      started: getTime(), timeoutSecs: secs,
                      cellId: cell.id, command: command)
  if verbose:
    echo &"[mdnb] {md.filename} cell {cell.id}: launched '{command}' (timeout {secs}s)"
  if cell.properties.state == 'x':
    md.writeCellState(idx, 'r')         # x -> r so the user sees it flipped

const drainChunk = 8192   ## per-call read granularity; the loop stops at an empty pipe

proc drainOutput(r: var Running) =
  ## Pull whatever stdout is currently waiting on a running cell's pipe into its
  ## accumulator. The OS pipe buffer is tiny (~64KB); if we only read on exit, a
  ## cell whose output exceeds it fills the buffer and then the producer *blocks*
  ## writing to a full pipe — it never exits, the read never happens, and the
  ## cell hangs until its `timeout:` kills it (the pre-existing large-output
  ## bug). Draining every cycle keeps the pipe clear so the producer never blocks.
  ##
  ## `outputStream.readData` returns the number of bytes available *right now*,
  ## and returns 0 the instant the pipe is empty (it does not block on a live
  ## pipe), so this is a cheap non-blocking spin: read until a read yields 0,
  ## then return and let the process keep running. Memory is bounded downstream
  ## by `readTrimmed` when the accumulated bytes are shown.
  let s = r.p.outputStream
  var buf: array[drainChunk, char]
  while true:
    let n = s.readData(addr buf[0], drainChunk)
    if n == 0: break                     # pipe momentarily empty; cell may still run
    # Append the chunk to the accumulator. string.add has no openArray[char]
    # overload, so grow explicitly and copy (the same shape Nim's readAll uses).
    let prev = r.acc.len
    r.acc.setLen(prev + n)
    copyMem(addr r.acc[prev], addr buf[0], n)
  # NB: do NOT call readAll here — it loops until EOF, so it would block on a
  # still-running cell, defeating the whole point. Per-cycle drain only.

proc readTrimmed(s: Stream; tail: bool; n: int): string =
  ## Stream a source (a process pipe or a file) through a trim window so an
  ## enormous input is never read fully into memory before the lines to keep are
  ## chosen:
  ##   - `head` (`tail == false`): keep the first `n` lines, then *stop reading*.
  ##     The rest of the stream is left unread, so the cost scales with `n`, not
  ##     with the input size. (The exact number of lines cut is therefore
  ##     unknown — the footer reports that further content was truncated, without
  ##     a count, rather than draining the whole stream just to count it.)
  ##   - `tail` (`tail == true`): read the whole stream but retain only the last
  ##     `n` lines in a rolling buffer, so peak memory is still `n` lines, not
  ##     the input size. The exact count cut is reported.
  ## A no-op (no footer) when the content already fits, and a one-line footer
  ## naming the mode and limit appended when lines are actually dropped. Default
  ## `trim:head,50` (resolved in `processBodyForCells`) bounds every `show:` cell.
  if n <= 0: return ""
  if not tail:
    var kept: seq[string] = @[]
    while kept.len < n and not s.atEnd:
      kept.add(s.readLine())          # read only as many lines as we keep
    if kept.len == 0: return ""
    let core = kept.join("\n").strip()  # bounded by n lines — never the raw stream
    if core.len == 0: return ""         # whitespace-only content reads as empty
    if s.atEnd: return core             # content fit within n lines — no footer
    core & &"\n... (trim:head,{n} — further content truncated)"
  else:
    var ring = newSeq[string](n)        # rolling buffer of the last n lines
    var filled = 0
    var pos = 0                         # write cursor once the ring is full
    var total = 0
    while not s.atEnd:
      let line = s.readLine()
      inc total
      if filled < n:
        ring[filled] = line; inc filled
      else:
        ring[pos] = line; pos = (pos + 1) mod n
    if total == 0: return ""
    var kept: seq[string]
    if filled < n: kept = ring[0 ..< filled]
    else:
      kept = newSeq[string](n)
      for k in 0 ..< n: kept[k] = ring[(pos + k) mod n]   # unwind to original order
    let core = kept.join("\n").strip()
    if core.len == 0: return ""
    if total > n:
      core & &"\n... (trim:tail,{n} — {total - n} lines truncated)"
    else: core

proc reapFinished(md: var MarkdownFile; r: var Running) =
  ## Read the finished process's stdout, write it in full to its `output:` file,
  ## write a trimmed view into any matching `show:` cell of the current md, then
  ## flip the cell `r` -> `s`. The on-disk `output:` file is intentionally
  ## untrimmed — it holds the real, complete output. Trimming is a display
  # concern: it's applied only when content is read into a `show:` cell, so the
  # source of truth on disk is never truncated. Notices mdnb authors itself
  # (the timeout-kill notice, `(please wait)`, `(empty output)`) are written
  # verbatim — only captured subprocess output is trimmed for display.
  #
  # Non-zero exit (Tier 3): when the command did not exit cleanly, prepend an
  # mdnb-authored notice naming the exit code to both the `output:` file and the
  # `show:` cell, so the failure is unambiguous even when the command printed
  # nothing. stderr is already merged into the captured output (`poStdErrToStdOut`
  # in startRun), so the command's own error text is in `raw`; the notice just
  # flags the failure. The notice is prepended to the captured output and the
  # combined text is what's trimmed for display, so under the default
  # `trim:head,N` the notice stays pinned at the top.
  # The bulk of the output was drained incrementally by `pollRuns`/`drainOutput`
  # while the cell ran (to keep the OS pipe from filling and blocking the
  # producer); drain the final tail bytes the process wrote between the last poll
  # and exiting, then read from the accumulator rather than the pipe.
  r.drainOutput
  let exitCode = r.p.peekExitCode
  r.p.close
  # Ephemeral bare-block cell: it ran for its side effects only — no `output:`
  # file is kept and there is no `show:` cell to fill. The tmp source stays on
  # disk as a CACHE so an unchanged bare block does not re-run on the next save
  # (see markDirtyCells: it skips a cell whose source file matches its content).
  # `:clean` is what wipes these; editing the block changes its content-derived
  # filename, so the stale cache file is simply left behind (harmless) and the
  # new one is missing -> dirty -> runs. Just report status and settle state.
  if r.ephemeral:
    r.logRunStatus(exitCode)
    for i, c in md.cells:
      if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
        md.writeCellState(i, 's')
        break
    return
  let raw = r.acc.strip
  let errored = exitCode != 0          # reapFinished is only reached once finished, so != 0 means failed
  let body =
    if errored and raw.len > 0:
      &"(mdnb: cell exited with code {exitCode})\n" & raw
    elif errored:
      &"(mdnb: cell exited with code {exitCode})"
    else:
      raw
  r.outputFile.safeWriteFile(body)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    # Stream the full output through the producer cell's trim window for display.
    # The producer cell carries the `trim:` settings (resolved at parse time) so
    # the `show:` cell reflects them without the user having to redeclare `trim:`
    # on the show block.
    let props = cellWithSource(md, r.sourceFile)
    let shown = readTrimmed(newStringStream(body), props.trimTail, props.trimLines)
    md.writeIntoCell(showIdx, if shown.len > 0: shown else: "(empty output)")
    md.write
  # Verbose execution status (Tier 3): cell id, command, exit code, duration.
  r.logRunStatus(exitCode)
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
  let exitCode = r.p.peekExitCode
  r.p.close
  # Ephemeral bare-block cell: no `output:`/`show:` to write a notice into. The
  # tmp source stays on disk as a cache (wiped by `:clean`). Just report status.
  if r.ephemeral:
    r.logRunStatus(exitCode, note = &"killed (timeout:{r.timeoutSecs}s)")
    for i, c in md.cells:
      if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
        md.writeCellState(i, 's')
        break
    return
  let notice = &"(mdnb killed this cell: exceeded timeout:{r.timeoutSecs}s)"
  r.outputFile.safeWriteFile(notice)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    md.writeIntoCell(showIdx, notice)
    md.write
  # Verbose execution status (Tier 3): the killed cell still gets a status line.
  r.logRunStatus(exitCode, note = &"killed (timeout:{r.timeoutSecs}s)")
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
          let exitCode = running[j].p.peekExitCode
          running[j].p.close
          # Verbose execution status (Tier 3): report the manually-killed cell.
          running[j].logRunStatus(exitCode, note = "killed ([k])")
          running.delete j
          md.cells[i].properties.state = 's'
          md.writeCellState(i, 's')
          break
  # Then reap whatever has finished on its own, or kill any past its timeout
  # (this file's processes only). Drain each of this file's running cells first:
  # the OS pipe buffer is ~64KB, so without a per-cycle drain a cell whose output
  # exceeds it blocks the producer on a full pipe and can never exit — the
  # timeout below would then kill it before any output landed (see drainOutput).
  let now = getTime()
  var i = 0
  while i < running.len:
    if running[i].filename != md.filename:
      inc i                              # belongs to another watched file
    else:
      running[i].drainOutput             # keep the pipe clear; acc accumulates stdout
      if now - running[i].started >= initDuration(seconds = running[i].timeoutSecs):
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

proc sweepEphemeralCache(md: var MarkdownFile) =
  ## Garbage-collect orphaned bare-block (ephemeral) tmp files for *this* md
  ## file. Each run leaves a cache file per distinct cell body, named
  ## `<mdname>_tmp_<hash>.<ext>`; when a cell's body changes (new hash) or a cell
  ## is deleted, its old file becomes an orphan. Rather than track "the last
  ## filename" per cell (which needs a stable cross-parse identity cell ids can't
  ## provide), we treat the filesystem as the map: after parsing, mdnb knows every
  ## CURRENT cell's source path, so any mdnb-authored tmp file for this md that
  ## isn't a current source is an orphan and is deleted here. Files still in use
  ## by a running subprocess are spared (a cell edited mid-run keeps its source
  ## until the run is reaped). Per-md: a multi-file run never touches another
  ## file's cache. Stateless — no map to maintain or corrupt.
  let base = splitFile(md.filename).name
  # Sources the current parse knows about, plus any file a running cell still
  # needs (an edited-while-running cell's source is live until it's reaped).
  var keep: HashSet[string]
  for cell in md.cells:
    if cell.properties.code and cell.properties.source.len > 0:
      keep.incl cell.properties.source
  for r in running:
    if r.sourceFile.len > 0: keep.incl r.sourceFile
  for path in walkFiles(base & "_tmp_*"):
    if path in keep: continue
    # Only sweep files matching mdnb's exact ephemeral naming (not a user file
    # that merely contains `_tmp_`): the name must end in `_tmp_<8hex>.<ext>`.
    if not path.looksEphemeral: continue
    tryRemoveFile(path)

proc runCells(md: var MarkdownFile) =
  ## Launch every cell that should run this pass (dirty, or `[x]`-forced) and
  ## reap any that finished since last cycle. Non-blocking: long cells are
  ## left in `running` and reaped on subsequent calls rather than blocking here.
  createDir "temp"
  md.sweepEphemeralCache
  md.pollRuns
  for i, cell in md.cells:
    if cellShouldRun(cell):
      md.startRun(i)
    elif not cell.properties.code:
      # Non-runnable `show:` cell: read its file back in if it already exists
      # (e.g. output landed on a previous pass, or from a prior session). The
      # file is streamed through the cell's trim window (`trim:head,N` /
      # `trim:tail,N`, default `head,50`) so an enormous file is never read
      # fully into memory and the markdown only ever shows the trimmed view —
      # the on-disk file stays the complete source of truth. Cells whose
      # producer is still running get their freshest output on a later cycle
      # via reapFinished.
      let target = cell.properties.show
      if fileExists(target):
        let fs = newFileStream(target, fmRead)
        if fs != nil:
          let shown = readTrimmed(fs, cell.properties.trimTail,
                                  cell.properties.trimLines)
          fs.close
          md.writeIntoCell(i, shown)
          md.write
