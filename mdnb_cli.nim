## CLI and the watch loop. Parses args, polls each watched file's mtime every 500ms, debounces saves closer together than `debounceInterval`, and runs the pipeline on change. Native watchers (inotify/FSEvents) are deliberately not used (agents.md §6 `main`).
## Async (Tier 2): each `md` is kept alive across cycles so a long-running cell is reaped on a later cycle without blocking; every cycle reaps finished subprocesses for every watched file, so cell A's slow run never blocks cell B's output in another file. `debounceInterval` is a save-spacing guard (two saves closer together, by mtime, are treated as one), not a poll-rate change — polling stays at 500ms.
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
  # Verbose execution status (Tier 3): `-v`/`--verbose` enables per-run status logging (cell id, command, exit code, duration). Off by default.
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
        # Ignore mdnb's own writes: a change whose mtime matches one we just wrote is our feedback, not a user save (otherwise a write-then-detect loop forms, especially now that async cells leave `(please wait)` on disk while still running).
        if curTime == selfWriteTimes[idx]:
          continue
        # Debounce: a save closer than `debounceInterval` to the last processed one for this file is ignored (the run-once `-o` path is exempt). Measured by mtime, matching the "at least 1 second apart" rule.
        if looping and curTime - processedTimes[idx] < debounceInterval:
          continue
        var md = newMarkdownFile(filename)
        if not looping:
          md.cleanBuild = true
          # Tier 4: `-o` is a clean build, so force every cell to run regardless of `[s]`, preserving run-once's full-output contract under stopped-by-default. Route through the SEQUENTIAL bulk path (`runMode = rmAll`) so producers finish before consumers — `-o` must behave like `:runall`, not a concurrent fan-out, or an `in:`/`out:` chain breaks.
          md.runMode = rmAll
        md.process
        processedTimes[idx] = curTime
        # Record the mtime mdnb left behind, so its write is recognized as self-feedback and skipped on the next poll.
        selfWriteTimes[idx] = getLastModTime(filename)
      elif anyRunning(filename):
        # Async reaping (Tier 2): a cell launched on an earlier save may have finished. If the user saved WHILE a cell was running (e.g. typed `[k]`, or edited another cell), that save must go through the FULL `process` pipeline (not just the reap-only path) — otherwise the `[k]` would be absorbed by this branch's bookkeeping. So detect a user save here and run the whole pipeline; otherwise just reap.
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
          # A reap may have written output/state back; record that mtime as our own so the next poll skips it.
          selfWriteTimes[idx] = getLastModTime(filename)
          modTimes[idx] = selfWriteTimes[idx]
    if looping:
      sleep(500)
    else:
      # Run-once (`-o`): one-shot mode expects full output before exit, so block here until every launched cell is reaped, then finish.
      while running.len > 0:
        for filename in params:
          var md = newMarkdownFile(filename)
          md.processYamlHeader
          md.processBodyForCells
          md.pollRuns
        if running.len > 0: sleep(100)
      break
