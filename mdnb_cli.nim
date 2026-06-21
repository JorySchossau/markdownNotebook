## CLI and the watch loop. Parses args, polls each watched file's mtime every
## 500ms, debounces saves closer together than `debounceInterval`, and runs the
## pipeline on change. Native watchers (inotify/FSEvents) are deliberately not
## used — mdnb stays cross-platform. See agents.md §6 (`main`).
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

  if params.len == 0 or not params.allIt(fileExists(it)):
    echo "Error: specify markdown filename(s) and optionally -o for run once"
    quit()

  var modTimes = newSeq[Time](params.len)
  var processedTimes = newSeq[Time](params.len)
  for idx, filename in params:
    modTimes[idx] = if looping: getLastModTime(filename)
                    else: getLastModTime(filename) - 1.minutes
    processedTimes[idx] = modTimes[idx]

  echo "started"
  while true:
    for idx, filename in params:
      let curTime = getLastModTime(filename)
      if modTimes[idx] < curTime:
        modTimes[idx] = curTime
        # Debounce: a save closer than `debounceInterval` to the last one we
        # actually processed for this file is ignored (the run-once `-o` path is
        # exempt). The gap is measured by mtime, matching the "at least 1 second
        # apart" rule, so it is independent of how we happen to poll.
        if looping and curTime - processedTimes[idx] < debounceInterval:
          continue
        var md = newMarkdownFile(filename)
        if not looping: md.cleanBuild = true
        md.process
        processedTimes[idx] = curTime
    if looping: sleep(500)
    else: break
