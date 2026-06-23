## Cell command interpretation: turn info-string tokens (`source:`/`append:`/`output:`/`[T](S)`/`timeout:`/`trim:`…) into `CellProperties`. Extracted from `processBodyForCells` so the PEG scanner stays a positional concern and command parsing grows on its own (agents.md §8 recipe: add a `case` branch here). On any invalid command/state content, write a `Skipping cell:` notice to **stderr** and mark the cell invalid so `processBodyForCells` drops it (mdnb never crashes on a bad cell definition line).
proc parseCellCommands(matches: seq[string]; md: MarkdownFile): tuple[props: CellProperties, invalid: bool] =
  result.props = CellProperties()
  for i, match in matches:
    if i == 0: continue
    if match.len == 0: break
    if i == 1 and (match in md.runtimes or match == "raw"):
      result.props.language = match
    # Two-field control `[T](S)`: trigger T∈{x,o,space} (empty/space = do-nothing), run-state S∈{r,s,k}. A loose shape match delivers the whole token here; this validates the content. `[]` (empty brackets, no parens) is the legacy single-field form and is NOT recognized — the cell mis-parses and is skipped with a stderr notice.
    if match.len >= 5 and match[0] == '[' and match[2] == ']' and match[3] == '(' and match[match.len - 1] == ')':
      let trigCh = match[1]                       # trigger slot (1 char inside `[ ]`)
      let stCh = match[4]                         # state slot (1 char inside `( )`)
      if match.len != 6 or trigCh notin {' ', 'x', 'o'}:
        stderr.writeLine &"Skipping cell: invalid trigger '{trigCh}' in '{match}' (expected x / o / blank)"
        result.invalid = true
      elif stCh notin {'r', 's', 'k'}:
        stderr.writeLine &"Skipping cell: invalid state '{stCh}' in '{match}' (expected r / s / k)"
        result.invalid = true
      else:
        result.props.trigger = if trigCh == ' ': ' ' else: trigCh
        result.props.state = stCh
      continue
    let command = match.split(':')
    case command[0]
    of "source":
      if result.props.isAppend:
        stderr.writeLine "Skipping cell: 'source:' and 'append:' are mutually exclusive"
        result.invalid = true
      else:
        result.props.code = true
        if command.len == 2: result.props.source = command[1]
    of "append":
      if result.props.source.len > 0:
        stderr.writeLine "Skipping cell: 'source:' and 'append:' are mutually exclusive"
        result.invalid = true
      elif command.len != 2:
        stderr.writeLine "Skipping cell: argument required: 'append:filename'"
        result.invalid = true
      else:
        result.props.code = true
        result.props.isAppend = true
        result.props.source = command[1]
    of "output", "show", "inputs":
      # Guard the arg access behind `else` (mirroring `append`): a bare `output`/`show`/`inputs` with no `:arg` has len 1, so `command[1]` would IndexDefect without this branch.
      if command.len != 2:
        stderr.writeLine "Skipping cell: argument required: 'command:argument'"
        result.invalid = true
      else:
        case command[0]
        of "output":
          result.props.code = true
          result.props.output = command[1]
        of "show": result.props.show = command[1]
        of "inputs": result.props.inputs = command[1].split(',')
        else: discard
    of "timeout":
      if command.len != 2:
        stderr.writeLine "Skipping cell: argument required: 'timeout:N' (seconds)"
        result.invalid = true
      else:
        try: result.props.timeout = parseInt(command[1])
        except ValueError:
          stderr.writeLine &"Skipping cell: 'timeout:N' expects an integer, got '{command[1]}'"
          result.invalid = true
    of "trim":
      # `trim:head,N` / `trim:tail,N` (comma-separated, no spaces) — parses under the existing `word ':' word` grammar like `inputs:a,b,c`.
      if command.len != 2:
        stderr.writeLine "Skipping cell: argument required: 'trim:head,N' / 'trim:tail,N'"
        result.invalid = true
      else:
        let parts = command[1].split(',')
        if parts.len != 2 or parts[0] notin ["head", "tail"]:
          stderr.writeLine &"Skipping cell: 'trim' wants head,N or tail,N, got '{command[1]}'"
          result.invalid = true
        else:
          try:
            let n = parseInt(parts[1])
            if n <= 0: raise newException(ValueError, "non-positive")
            result.props.trimTail = parts[0] == "tail"
            result.props.trimLines = n
          except ValueError:
            stderr.writeLine &"Skipping cell: 'trim' count expects a positive integer, got '{parts[1]}'"
            result.invalid = true
    else: discard
