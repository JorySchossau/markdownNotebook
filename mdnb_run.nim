## Execution: build the shell command for a cell and run the dirty ones. Runs are non-blocking (Tier 2): launched via `osproc.startProcess`, reaped on a later watch cycle via `pollRuns`, with `[s/r/x/k]` state for manual control, per-cell `timeout:` (Tier 2), and per-cycle pipe draining (Tier 2) so output > the ~64KB OS pipe buffer can't block the producer (agents.md §8/§12).

proc buildCommand(command, sourceFilename: string): string =
  ## If `command` has `$1`, replace each with `sourceFilename` minus extension (compiled-language form `g++ -o $1.out $1.cpp`); else append the source filename.
  if "$1" in command:
    let (dir, name, _) = sourceFilename.splitFile
    command.replace("$1", dir / name)
  else:
    command & ' ' & sourceFilename

## ==============
## Non-blocking run state. Keyed by source file path (unique per cell). The watch loop rebuilds a fresh `MarkdownFile` per save, so a running cell can't hold a pointer to its origin `md`; we keep just enough to reap the process and write its output to the cell's `output:` path, locating the show cell in whichever `md` is current at reap time.
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
  acc: string                ## drained-so-far stdout; pipe buffer is ~64KB, so a cell whose output exceeds it would block forever writing to a full pipe if we only read on exit (see drainOutput).

var running: seq[Running]    ## currently-executing cell subprocesses (module-global)
var verbose: bool            ## set by `-v`/`--verbose`; gates per-run status logging

proc logRunStatus(r: Running; exitCode: int; note = "") =
  ## Verbose status (Tier 3): one line per completed cell — id, command, exit code, duration. Gated on `-v`; `note` overrides the exit code for kills (post-SIGKILL `peekExitCode` is unreliable).
  if not verbose: return
  let dur = (getTime() - r.started).inMicroseconds.float / 1_000_000.0
  let tail = if note.len > 0: note else: "exit " & $exitCode
  echo &"[mdnb] {r.filename} cell {r.cellId}: '{r.command}' -> {tail} in {dur:.3f}s"

proc anyRunning(filename: string): bool =
  ## True if any in-flight cell belongs to `filename` (whether the watch loop should do a reap pass for a file not just saved).
  for r in running:
    if r.filename == filename: return true
  false

proc writeCellState(md: var MarkdownFile; idx: int; newState: char) =
  ## 1-for-1 swap of the state char in this cell's `[x]` field (no offset patching needed); no-op if the cell has no `[ ]` field.
  if newState == '\0': return
  let cell = md.cells[idx]
  # Scan back from the cell body to the info line, take its last `[` as the `[x]` field (don't break on `]` — scanning backwards hits the close bracket first).
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
  ## The `CellProperties` of the code cell writing `sourceFile` — used to find the `trim:` settings governing a show cell's display (producer carries the trim window). Returns default (head,50) if not found.
  for c in md.cells:
    if c.properties.code and c.properties.source == sourceFile:
      return c.properties
  CellProperties(trimLines: defaultTrimLines)

proc cellShouldRun(cell: Cell): bool =
  ## Tier 4 stopped-by-default: only `x` runs; absent/`s`/`r`/`k` do not. (`-o` bypasses this by setting `runMode = rmAll`, so `runBulk` forces `[x]` itself via `runCellsSequential`.)
  if not cell.properties.code: return false
  case cell.properties.state
  of 'x': return true                    # execute: force-run regardless of dirty
  of 's', 'r', 'k': return false         # stopped / running / kill-requested
  else: return false                     # '\0' (no field): stopped by default now

proc startRun(md: var MarkdownFile; idx: int) =
  ## Launch one cell's process without blocking: write the source, start the subprocess (or write output directly for `raw`), record it in `running`, flip state `x`->`r`. Persists the command signature sidecar for non-ephemeral cells so a later `markDirtyCells` detects command edits.
  let cell = md.cells[idx]
  let sourceFile = cell.properties.source
  let outputFile = cell.properties.output
  let ephemeral = cell.properties.ephemeral
  sourceFile.safeWriteFile(md.sources[sourceFile])
  # Record the command signature that produced this source so a command/arg/language edit re-runs even when the body (and thus the source) is byte-identical. Ephemeral cells fold the signature into their cache filename instead.
  if not ephemeral:
    writeSigSidecar(sourceFile, md.sourceSigs[sourceFile])
  let language = cell.properties.language
  if language == "raw":
    # raw blocks produce no subprocess; their body IS the output. Synchronous.
    md.sources[sourceFile].strip.safeWriteFile(outputFile)
    return
  let command = buildCommand(md.runtimes[language].command, sourceFile)
  # poEvalCommand routes through the shell (sh -c), matching the old blocking execProcess; poStdErrToStdOut merges stderr into the captured output.
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
    md.cells[idx].properties.state = 'r'  # keep in-memory state synced with the file so a caller holding this `md` across runs (the Tier 4 sequential path) sees `r` and `reapFinished` can flip it to `s`.
    md.writeCellState(idx, 'r')         # x -> r so the user sees it flipped

const drainChunk = 8192   ## per-call read granularity; the loop stops at an empty pipe

proc drainOutput(r: var Running) =
  ## Pull captured stdout out of a FINISHED process's pipe into `acc` (at EOF `readData` returns 0 and never blocks, so it reads everything in one pass). Memory is bounded downstream by `readTrimmed`. Never call on a still-running cell — see `pollRuns`.
  let s = r.p.outputStream
  var buf: array[drainChunk, char]
  while true:
    let n = s.readData(addr buf[0], drainChunk)
    if n == 0: break                     # pipe momentarily empty; cell may still run
    # Append the chunk to the accumulator. string.add has no openArray[char] overload, so grow explicitly and copy (the same shape Nim's readAll uses).
    let prev = r.acc.len
    r.acc.setLen(prev + n)
    copyMem(addr r.acc[prev], addr buf[0], n)
  # NB: do NOT call readAll here — it loops until EOF, so it would block on a still-running cell, defeating the whole point. Per-cycle drain only.

proc readTrimmed(s: Stream; tail: bool; n: int): string =
  ## Stream a source through a trim window so an enormous input is never read fully into memory: `head` keeps the first `n` lines then stops reading (footer says "further content truncated", no count); `tail` keeps a rolling buffer of the last `n` lines (footer reports the exact count cut). No-op (no footer) when the content fits. Default `trim:head,50` (resolved in `processBodyForCells`).
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

## ==============
## md-viewer image-cache refresh. Viewers cache inline images by URL, so a cell regenerating an image without changing its filename (the normal mdnb workflow) leaves the viewer showing stale pixels. The trick: two passes over the prose's image references with a save between them — pass 1 perturbs each URL with a visual no-op the cache is sensitive to, pass 2 reverts it. Each save forces a re-decode. The file ends byte-identical to its pre-refresh state. Two flavors are handled: classic `![desc](url)` (append `#0`) and html `<img src="...">` (append a trailing space, collapsed by the renderer). Scans prose GAPS only (never inside a fenced block).

proc transformImageUrl(url, fragSuffix: string): string =
  ## Apply/revert the `#0` perturbation to a classic-markdown image URL. Idempotent (appending when already present is a no-op).
  if fragSuffix.len == 0:
    if url.endsWith("#0"): result = url[0 ..< url.len - 2]
    else: result = url
  else:
    if url.endsWith(fragSuffix): result = url      # already perturbed; leave as-is
    else: result = url & fragSuffix

proc perturbHtmlSrcValue(val, fragSuffix: string): string =
  ## Apply/revert the trailing-space perturbation to an html `<img src="...">` value (`fragSuffix` is just a non-empty flag here). Idempotent both directions.
  if fragSuffix.len > 0:
    if val.endsWith(" "): result = val
    else: result = val & " "
  else:
    if val.endsWith(" "): result = val[0 ..< val.len - 1]
    else: result = val

proc applyToProseMarkdownImages(md: var MarkdownFile; fragSuffix: string;
                                 imgCount: var int) =
  ## Walk every prose gap and rewrite each classic-markdown image URL via `transformImageUrl`. Fenced blocks (inside a cell's `rng`) are skipped. `imgCount` accumulates rewrites for verbose reporting.
  var matches = newSeq[string](1)
  var endPrevChunk, startNextChunk = 0
  for cell_i in 0 .. md.cells.len:
    startNextChunk = if cell_i == md.cells.len: md.buf[].len - 1
                     else: md.cells[cell_i].rng.a
    var pos: tuple[first, last: int] = (-1, 0)
    while true:
      matches[0] = ""
      pos = md.buf[][endPrevChunk .. startNextChunk].findBounds(mdImagePattern,
                                                                matches, start = pos.last)
      if pos.first == -1: break
      # `matches[0]` is the captured URL; `pos.first` is the `!`, `pos.last` the closing `)`. URL start = endPrevChunk + pos.last - matches[0].len (slice index 0 == buffer index endPrevChunk).
      let urlStart = endPrevChunk + pos.last - matches[0].len
      let newUrl = transformImageUrl(matches[0], fragSuffix)
      if newUrl != matches[0]:
        md.buf[] = md.buf[][0 ..< urlStart] & newUrl &
                   md.buf[][urlStart + matches[0].len .. ^1]
        let delta = newUrl.len - matches[0].len
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, delta)
        startNextChunk += delta
        inc imgCount
      # Advance past this URL so the next scan continues after it.
      pos = (pos.first, pos.first + (if newUrl != matches[0]: newUrl.len - 1
                                     else: matches[0].len - 1))
    endPrevChunk = startNextChunk

proc findHtmlImgSrc(buf: string; gapA, gapB: int;
                    outUrlStart, outUrlEnd: var int): bool =
  ## Manual scan for the next `<img ... src="..." ...>` src value within the prose gap `[gapA .. gapB]`. Returns true with `outUrlStart`/`outUrlEnd` set to the value bytes (exclusive of quotes). Hand-written rather than a PEG because Nim PEGs can't cleanly express arbitrary html attribute shapes (quoted/unquoted/mixed).
  var i = gapA
  while i <= gapB - 4:
    if buf[i] == '<' and buf[i + 1] == 'i' and buf[i + 2] == 'm' and
       buf[i + 3] == 'g':
      # Found `<img` — scan attributes within this tag until `>` or end of gap.
      var j = i + 4
      var foundSrc = false
      var srcStart, srcEnd = 0
      var q: char = '\0'
      while j <= gapB:
        let c = buf[j]
        if c == '>':
          break                            # end of tag
        if c == ' ' or c == '\t' or c == '\n' or c == '/':
          inc j; continue                  # skip whitespace and self-close slash
        # Read an attribute name up to '=' or whitespace.
        let nameStart = j
        while j <= gapB and buf[j] != '=' and buf[j] != ' ' and
              buf[j] != '\t' and buf[j] != '\n' and buf[j] != '>' : inc j
        let name = buf[nameStart ..< j]
        if j <= gapB and buf[j] == '=':
          inc j                             # consume '='
          while j <= gapB and (buf[j] == ' ' or buf[j] == '\t'): inc j  # skip ws
          if j <= gapB and (buf[j] == '"' or buf[j] == '\''):
            q = buf[j]; inc j               # opening quote
            let valStart = j
            while j <= gapB and buf[j] != q: inc j
            if j <= gapB:
              # quoted value spans [valStart ..< j]; closing quote at j.
              if name == "src" and not foundSrc:
                foundSrc = true
                srcStart = valStart
                srcEnd = j                 # exclusive end of value
              inc j                         # consume closing quote
            else:
              break                         # unterminated quote; bail on tag
          else:
            # Unquoted value: run of non-whitespace, non->.
            while j <= gapB and buf[j] != ' ' and buf[j] != '\t' and
                  buf[j] != '\n' and buf[j] != '>': inc j
        else:
          # bare attribute (no value) — name already consumed; loop continues.
          discard
      if foundSrc:
        outUrlStart = srcStart
        outUrlEnd = srcEnd
        return true
      i = j                                 # tag had no src; resume after it
    else:
      inc i
  false

proc applyToProseHtmlImages(md: var MarkdownFile; fragSuffix: string;
                             imgCount: var int) =
  ## Walk every prose gap and rewrite each `<img src="...">` value via `perturbHtmlSrcValue`. Same gap-walking/offset-patching as `applyToProseMarkdownImages`; the tag is located by `findHtmlImgSrc`.
  var endPrevChunk, startNextChunk = 0
  for cell_i in 0 .. md.cells.len:
    startNextChunk = if cell_i == md.cells.len: md.buf[].len - 1
                     else: md.cells[cell_i].rng.a
    var scanFrom = endPrevChunk
    while true:
      var urlStart, urlEnd = 0
      if not md.buf[].findHtmlImgSrc(scanFrom, startNextChunk, urlStart, urlEnd):
        break
      let oldVal = md.buf[][urlStart ..< urlEnd]
      let newVal = perturbHtmlSrcValue(oldVal, fragSuffix)
      if newVal != oldVal:
        md.buf[] = md.buf[][0 ..< urlStart] & newVal &
                   md.buf[][urlEnd .. ^1]
        let delta = newVal.len - oldVal.len
        if cell_i < md.cells.len:
          md.updatePositionsByOffset(md.cells[cell_i].id, delta)
        startNextChunk += delta
        urlEnd = urlStart + newVal.len
        inc imgCount
      # Continue scanning after this value.
      scanFrom = urlEnd
    endPrevChunk = startNextChunk

import std/os
proc refreshImageCache(md: var MarkdownFile) =
  ## Run the perturb/revert trick so a regenerated image (same filename, new pixels) shows up. Pass 1 rewrites URLs and saves; pass 2 reverts and saves. No-op (no extra saves) when the prose has no image references. Called from `reapFinished`.
  var imgCount = 0
  # Pass 1: perturb. Append `#0` to markdown URLs, a trailing space to html src.
  md.applyToProseMarkdownImages("#0", imgCount)
  md.applyToProseHtmlImages("#0", imgCount)
  if imgCount == 0:
    if verbose: echo "[mdnb] image-cache refresh: no inline images found, skipping"
    return
  md.write
  sleep(50) # sleep a bit so the viewer has a chance to recognize the change
  if verbose: echo &"[mdnb] image-cache refresh pass 1 (perturb): {imgCount} image(s)"
  # Pass 2: revert. Strip the `#0` fragment / collapse the trailing space.
  var revertCount = 0
  md.applyToProseMarkdownImages("", revertCount)
  md.applyToProseHtmlImages("", revertCount)
  md.write
  if verbose: echo &"[mdnb] image-cache refresh pass 2 (revert): {revertCount} image(s)"

## ==============

proc reapFinished(md: var MarkdownFile; r: var Running) =
  ## Read the finished process's stdout, write it in full to its `output:` file (untrimmed — the source of truth), write a trimmed view into any matching `show:` cell, flip state `r`->`s`. Non-zero exit (Tier 3): prepend an `(mdnb: cell exited with code N)` notice (stderr already merged via poStdErrToStdOut). The bulk was drained incrementally by `pollRuns`; drain the final tail here and read from `acc`.
  r.drainOutput
  let exitCode = r.p.peekExitCode
  r.p.close
  # Ephemeral bare-block cell: ran for side effects; no output/show cell to fill. The tmp source stays as a CACHE; editing the block changes its hash -> orphan (swept next run) -> missing -> dirty. Just report status and settle state, then refresh the image cache.
  if r.ephemeral:
    r.logRunStatus(exitCode)
    for i, c in md.cells:
      if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
        md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
        md.writeCellState(i, 's')
        break
    md.refreshImageCache
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
    # Stream the full output through the producer cell's trim window for display (producer carries the `trim:` settings resolved at parse time).
    let props = cellWithSource(md, r.sourceFile)
    let shown = readTrimmed(newStringStream(body), props.trimTail, props.trimLines)
    md.writeIntoCell(showIdx, if shown.len > 0: shown else: "(empty output)")
    md.write
  r.logRunStatus(exitCode)
  # Flip the producing cell's state r -> s so the user sees it settled.
  for i, c in md.cells:
    if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
      md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
      md.writeCellState(i, 's')
      break
  md.refreshImageCache

proc reapTimeout(md: var MarkdownFile; r: Running) =
  ## Kill a cell that exceeded its `timeout:` and write a notice (naming the limit) into both its `output:` file and any matching `show:` cell. Mirrors `reapFinished` but substitutes the notice for the captured output.
  osproc.kill(r.p)
  let exitCode = r.p.peekExitCode
  r.p.close
  # Ephemeral bare-block cell: no output/show to write a notice into. The tmp source stays as a cache (wiped by `:clean`). Just report status.
  if r.ephemeral:
    r.logRunStatus(exitCode, note = &"killed (timeout:{r.timeoutSecs}s)")
    for i, c in md.cells:
      if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
        md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
        md.writeCellState(i, 's')
        break
    return
  let notice = &"(mdnb killed this cell: exceeded timeout:{r.timeoutSecs}s)"
  r.outputFile.safeWriteFile(notice)
  let showIdx = md.showCellForOutput(r.outputFile)
  if showIdx >= 0:
    md.writeIntoCell(showIdx, notice)
    md.write
  r.logRunStatus(exitCode, note = &"killed (timeout:{r.timeoutSecs}s)")
  for i, c in md.cells:
    if c.properties.code and c.properties.source == r.sourceFile and c.properties.state == 'r':
      md.cells[i].properties.state = 's'   # keep in-memory state synced with disk
      md.writeCellState(i, 's')
      break

proc pollRuns(md: var MarkdownFile) =
  ## Reap finished/killed subprocesses for `md.filename` non-blockingly every watch cycle (independent of mtime), honoring `[k]`. Reaps are file-scoped so file A's slow cell never blocks file B's cells.
  # First, honor kills: a cell now marked 'k' kills its running process.
  for i, cell in md.cells:
    if cell.properties.code and cell.properties.state == 'k':
      for j, r in running:
        if r.filename == md.filename and r.sourceFile == cell.properties.source:
          # osproc.kill sends SIGKILL; reap the corpse, drop from `running`, flip state k->s on disk AND in memory so the launch pass below doesn't immediately relaunch.
          osproc.kill(running[j].p)
          let exitCode = running[j].p.peekExitCode
          running[j].p.close
          running[j].logRunStatus(exitCode, note = "killed ([k])")
          running.delete j
          md.cells[i].properties.state = 's'
          md.writeCellState(i, 's')
          break
  # Then reap whatever finished on its own, or kill any past its timeout (this file only). Decide fate BEFORE draining: readData blocks on an empty-but-live pipe (returns 0 only at EOF), so draining a silent still-running cell would hang the watcher and a `[k]` could never land.
  let now = getTime()
  var i = 0
  while i < running.len:
    if running[i].filename != md.filename:
      inc i                              # belongs to another watched file
    else:
      # Trade-off (agents.md §9): a running cell whose output exceeds the ~64KB pipe buffer blocks its own producer and is then killed by its `timeout:` — heavy-output cells need a generous `timeout:` and must fit the buffer, or be split. This keeps the watcher responsive (the priority).
      if now - running[i].started >= initDuration(seconds = running[i].timeoutSecs):
        md.reapTimeout(running[i])
        running.delete i
      elif running[i].p.peekExitCode == -1:
        inc i   # still running; leave it for a future cycle (do NOT drain)
      else:
        md.reapFinished(running[i])   # finished: drains at EOF inside reapFinished
        running.delete i

## ==============

proc sweepEphemeralCache(md: var MarkdownFile) =
  ## GC orphaned bare-block (ephemeral) tmp files for *this* md. The filesystem is the map: after parsing, mdnb knows every current cell's source, so any mdnb-authored tmp file for this md that isn't a current source (and isn't in use by a running subprocess) is an orphan and deleted. Per-md and stateless — no map to maintain.
  let base = splitFile(md.filename).name
  var keep: HashSet[string]
  for cell in md.cells:
    if cell.properties.code and cell.properties.source.len > 0:
      keep.incl cell.properties.source
  for r in running:
    if r.sourceFile.len > 0: keep.incl r.sourceFile
  for path in walkFiles(base & "_tmp_*"):
    if path in keep: continue
    # Only sweep files matching mdnb's exact ephemeral naming (`_tmp_<8hex>.<ext>`), never a user file that merely contains `_tmp_`.
    if not path.looksEphemeral: continue
    tryRemoveFile(path)

proc runCells(md: var MarkdownFile) =
  ## Launch every cell that should run this pass (`[x]`-forced) and reap any finished since last cycle. Non-blocking: long cells stay in `running` and are reaped later. Non-runnable `show:` cells with an existing file read it back in (streamed through their trim window).
  createDir "temp"
  md.sweepEphemeralCache
  md.pollRuns
  for i, cell in md.cells:
    if cellShouldRun(cell):
      md.startRun(i)
    elif not cell.properties.code:
      # Non-runnable `show:` cell: stream its file back in if it already exists (output landed on a prior pass, or from a prior session) through the cell's trim window; a still-running producer's output lands on a later cycle via reapFinished.
      let target = cell.properties.show
      if fileExists(target):
        let fs = newFileStream(target, fmRead)
        if fs != nil:
          let shown = readTrimmed(fs, cell.properties.trimTail,
                                  cell.properties.trimLines)
          fs.close
          md.writeIntoCell(i, shown)
          md.write

proc reapThis(md: var MarkdownFile; sourceFile: string; timeoutSecs: int; started: Time) =
  ## Block until the running cell identified by `sourceFile` is reaped, honoring its `timeout:` and `[k]`. Used by `runCellsSequential` so each cell fully completes before the next starts (visible x->r->s). Mirrors the watch loop's reap path: drain each spin, kill on timeout, call `reapFinished`.
  let deadline = started + initDuration(seconds = timeoutSecs)
  while true:
    var idx = -1
    for j, r in running:
      if r.filename == md.filename and r.sourceFile == sourceFile: idx = j; break
    if idx == -1: return   # no longer in `running` -> already reaped elsewhere
    # Honor a user-typed `[k]` on this cell between spins (parse current file).
    let killRequested = block:
      var kr = false
      for c in md.cells:
        if c.properties.code and c.properties.source == sourceFile and c.properties.state == 'k':
          kr = true; break
      kr
    if killRequested:
      osproc.kill(running[idx].p)
      let ec = running[idx].p.peekExitCode
      running[idx].p.close
      running[idx].logRunStatus(ec, note = "killed ([k])")
      running.delete idx
      # flip k -> s in the file
      for i, c in md.cells:
        if c.properties.code and c.properties.source == sourceFile:
          md.cells[i].properties.state = 's'
          md.writeCellState(i, 's')
          break
      return
    if getTime() >= deadline:
      md.reapTimeout(running[idx])
      running.delete idx
      return
    if running[idx].p.peekExitCode != -1:
      md.reapFinished(running[idx])
      running.delete idx
      return
    sleep(50)

proc runCellsSequential(md: var MarkdownFile; selectedIdx: seq[int]) =
  ## Tier 4 bulk-run core: run `selectedIdx` one at a time, fully completing each (x->r->s, output written, show cell filled) before the next. Forces each cell's state to `x` then launches via `startRun` and synchronously reaps via `reapThis`. Deliberately BLOCKS the watcher — ordering and per-cell file updates are the point and aren't possible with the non-blocking path. Dependencies (`inputs:`/`output:`) apply: `markDirtyCells` already ran.
  createDir "temp"
  md.sweepEphemeralCache
  md.pollRuns
  for idx in selectedIdx:
    # Skip a cell already running (launched on a prior pass) — forcing a second launch would collide on the same source file.
    if idx < 0 or idx >= md.cells.len: continue
    if not md.cells[idx].properties.code: continue
    let secs = md.cells[idx].properties.timeout
    # Force the run trigger: set state x in memory and splice into the file, then startRun flips it to r and launches.
    md.cells[idx].properties.state = 'x'
    md.writeCellState(idx, 'x')
    md.startRun(idx)
    md.write   # x -> r visible before we block on the reap
    md.reapThis(md.cells[idx].properties.source, secs,
                if running.len > 0: running[^1].started else: getTime())
  # Refresh show cells whose files now exist but weren't a just-run producer (e.g. a show cell below all run cells displaying a pre-existing file).
  for i, cell in md.cells:
    if not cell.properties.code and cell.properties.show.len > 0:
      let target = cell.properties.show
      if fileExists(target):
        let fs = newFileStream(target, fmRead)
        if fs != nil:
          let shown = readTrimmed(fs, cell.properties.trimTail,
                                  cell.properties.trimLines)
          fs.close
          md.writeIntoCell(i, shown)
  md.write
