## CLI and the watch loop. Parses args, polls each watched file's mtime every
## 500ms, debounces saves closer together than `debounceInterval`, and runs the
## pipeline on change. Native watchers (inotify/FSEvents) are deliberately not
## used — mdnb stays cross-platform. See agents.md §6 (`main`).
##
## Asynchronous execution (Tier 2): each `md` is kept alive across cycles so a
## long-running cell can be **reaped** on a later cycle without blocking. Every
## cycle reaps finished subprocesses for every watched file (not only the one
## that just changed), so cell A's slow run never blocks cell B's output from
## landing in another file. See `mdnb_run.nim` for the run/reap layer.
## Two saves closer together than this (measured by their mtimes) are treated as
## one: the later one is ignored. Keeps a burst of mid-edit saves from each
## triggering a full cell run. Polling stays at 500ms; this is a save spacing
## guard, not a poll-rate change.
const debounceInterval = initDuration(seconds = 1)

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
  # Verbose execution status (Tier 3): `-v`/`--verbose` enables per-run status
  # logging to stdout (cell id, resolved command, exit code, duration). Off by
  # default so a normal run is unchanged.
  if params.anyIt(it in ["-v", "--verbose"]):
    verbose = true
    params.keepItIf(it notin ["-v", "--verbose"])

  if params.len == 0 or not params.allIt(fileExists(it)):
    echo "Error: specify markdown filename(s), optionally -o (run once), -v/--verbose (status)"
    quit()

  var modTimes = newSeq[Time](params.len)
  var processedTimes = newSeq[Time](params.len)
  var selfWriteTimes = newSeq[Time](params.len)   # mtimes of mdnb's own writes, to ignore
  for idx, filename in params:
    modTimes[idx] = if looping: getLastModTime(filename)
                    else: getLastModTime(filename) - 1.minutes
    processedTimes[idx] = modTimes[idx]
    selfWriteTimes[idx] = Time()

  echo "started"
  while true:
    for idx, filename in params:
      let curTime = getLastModTime(filename)
      if modTimes[idx] < curTime:
        modTimes[idx] = curTime
        # Ignore mdnb's own writes: a change whose mtime matches one we just
        # wrote is our feedback, not a user save, so don't reprocess (otherwise
        # a write-then-detect loop forms, especially now that async cells leave
        # `(please wait)` on disk while still running).
        if curTime == selfWriteTimes[idx]:
          continue
        # Debounce: a save closer than `debounceInterval` to the last one we
        # actually processed for this file is ignored (the run-once `-o` path is
        # exempt). The gap is measured by mtime, matching the "at least 1 second
        # apart" rule, so it is independent of how we happen to poll.
        if looping and curTime - processedTimes[idx] < debounceInterval:
          continue
        var md = newMarkdownFile(filename)
        if not looping:
          md.cleanBuild = true
          # Tier 4: `-o` is a clean build, so force every cell to run regardless
          # of `[s]` state, preserving run-once's full-output contract under
          # stopped-by-default. Route it through the SEQUENTIAL bulk path
          # (`runMode = rmAll`) rather than `forceRunAll`+non-blocking `runCells`,
          # so producer cells finish before their consumers start — `-o` must
          # behave like `:runall` (the spec), not a concurrent fan-out, or an
          # `inputs:`/`output:` chain breaks (consumer reads a file the producer
          # hasn't written yet).
          md.runMode = rmAll
        md.process
        processedTimes[idx] = curTime
        # Record the mtime of the file as mdnb left it, so the change mdnb just
        # caused (writing output/state back) is recognized as self-feedback and
        # skipped on the next poll rather than treated as a new user save.
        selfWriteTimes[idx] = getLastModTime(filename)
      elif anyRunning(filename):
        # Async reaping (Tier 2): a cell launched on an earlier save may have
        # finished since. Re-read the file, parse it, and reap so a long-running
        # cell's output lands even when no new save arrives — and a slow cell in
        # this file never blocks another watched file's saves from being
        # processed. Parsing is required so `reapFinished` can locate the show
        # cell to write the output into.
        #
        # But: if the user saved WHILE a cell was running (e.g. typed `[k]` to
        # kill it, or edited another cell), that save must go through the FULL
        # `process` pipeline (shortcut expansion, dirty-marking, run launching),
        # not just the reap-only path — otherwise the `[k]` would never be honored
        # because this branch's mtime bookkeeping would absorb it. So detect a
        # user save here (mtime advanced past what we last recorded and isn't our
        # own write) and run the whole pipeline; otherwise just reap.
        let curRun = getLastModTime(filename)
        if curRun != modTimes[idx] and curRun != selfWriteTimes[idx]:
          # A real user save arrived mid-run: process it fully (this also reaps).
          var md = newMarkdownFile(filename)
          md.process
          processedTimes[idx] = curRun
          selfWriteTimes[idx] = getLastModTime(filename)
          modTimes[idx] = selfWriteTimes[idx]
        else:
          var md = newMarkdownFile(filename)
          md.processYamlHeader
          md.processBodyForCells
          md.pollRuns
          # A reap may have written output/state back; record that mtime as our own
          # so the next poll skips it instead of treating mdnb's write as a save.
          selfWriteTimes[idx] = getLastModTime(filename)
          modTimes[idx] = selfWriteTimes[idx]
    if looping:
      sleep(500)
    else:
      # Run-once (`-o`): one-shot mode expects full output before exit, so block
      # here until every launched cell has been reaped, then finish.
      while running.len > 0:
        for filename in params:
          var md = newMarkdownFile(filename)
          md.processYamlHeader
          md.processBodyForCells
          md.pollRuns
        if running.len > 0: sleep(100)
      break
