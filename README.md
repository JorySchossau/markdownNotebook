Markdown Notebook is an editor-agnostic Jupyter Notebook-like experience for your markdown files. Code chunks are run and their output shown in your markdown file -- CommonMark specification is followed, so there is no special syntax that should break any markdown editor, renderer, or converter you want to use. It works best if your text editor supports smoothly reloading the file when a change is detected.

## What is it?

Markdown Notebook (mdnb) is a literate programming tool, inspired by the nifty [Emacs Babel Org Mode](https://orgmode.org/worg/org-contrib/babel/intro.html#org71e2aea). That is, instead of putting prose as comments into your source code, you can put source code into your prose, promoting better explanations, documentation, and readability. The use of markdown here allows for Emacs-like flexibility in handling various kinds of prose-level description formats like LaTeX, UML diagrams, and images (depending how you render or preview your markdown). I tried maybe 20 markdown editors, and while many work with basic editing, previewing, and reloading when changed, the [Zettlr](https://www.zettlr.com) Markdown Editor is the one I recommend for the best Jupyter Notebook-like experience. But a basic text editor like Vim also works well if you set it up to listen for file changes.

Related tools include:
* [Jupyter Notebooks](https://jupyter.org/)
* [VSCode Markdown Preview Enhanced Plugin Code Chunks](https://shd101wyy.github.io/markdown-preview-enhanced/#/code-chunk)
* [RStudio R-Markdown](https://rmarkdown.rstudio.com/lesson-3.html)
* [MDJS](https://medium.com/better-programming/introducing-mdjs-6bedba3d7c6f)
* [Hydrogen (Atom)](https://atom.io/packages/hydrogen)

## Why?

Jupyter Notebooks are great, but the software is gigantic, and the notebook files are not meant to be viewed directly as text files, making working with code versioning tools an annoying process. Also, you're beholden to whatever kernels exist to let your notebook know how to run your code. Why not use whatever you want for an editor and runnable languages?

## How does it work?

Markdown Notebook is not complicated. It works by running on the command line, and you telling it what markdown files you want it to watch for changes. When it detects a change, then it parses the file looking for runnable code chunks (markdown code fenced sections), runs the code, and shows the output if you've requested that, then refreshes your file with the modified content including code output.

Here are the steps:
* Wait for change before proceeding
* Parse markdown for code chunks
* Replace special keywords that expand to new code chunks or expand to a uri link
* Parse YAML header for supported languages in this file and how to run them
* Parse markdown for code chunks
* Only run code chunks if the resulting source files will change since last run
* Only run code chunks if the code chunk output does not exist as a file
* Show "(please wait") for output code chunks
* Run code chunks according to languages and commands described in YAML header
* Replace all output code chunks with the actual command output

## How to use it?

~~~
./mdnb myMarkdownFile.md (...more markdown files)
~~~

Optional flags:
* `-o` — run once and exit (also forces a clean build) instead of watching.
* `-v` / `--verbose` — print execution status to stdout: for every cell run, the cell id, the resolved system command, the exit code (or kill reason), and how long it took. Off by default so a normal run is quiet. Combine freely, e.g. `./mdnb -o -v myMarkdownFile.md`.

Then, open your markdown files in your favorite editor and `save` the file to update the code interpretation. Let's say you want to run bash and python code. You can make mdnb aware of such code blocks, and customize how that code is run through the YAML header. The full example is below, and the resulting transformed version is shown below that.

The frontmatter includes the ability to define different language codeblocks. The format is `code: <lang_name> <file_ext> <system_command>`
That is, the lang_name is the short name for the language, used possibly also conveniently as the code block markdown renderer syntax highlighting language name. file_ext is the file extension to use when saving to a temporary file in the current directory. system_command is the system command to which to pass the temporary filename to run the interpreter or compiler. The system_command may use `$1` as a placeholder for the source filename with its extension removed; each occurrence is replaced with that base path before running. This lets a single command both compile and run, e.g. `g++ -o $1.out $1.cpp && ./$1.out`. When `$1` is absent, the source filename is appended to the command (the default for interpreters like `python -OO`).

~~~
---
code: sh .sh sh
code: python .py "python -OO"
---

## Code Chunk Example

Some **Standard** Markdown

```sh output:bashdemo
echo "from the bash demo"
```

```show:bashdemo
```

``` python source:pydemo.py
# start of the python example code
from cowpy import cow
import text_to_image
from PIL import Image, ImageDraw, ImageFont
from resizeimage import resizeimage
import os
```

We can continue an explanation, and then add more code to a source file as we build our explanation.

```python append:pydemo.py output:pydemo.txt
msg = cow.Small().milk("mdnb!")
print(msg)
```

We can use the `show:file` shortcut directly; it will be replaced for us.

show:pydemo.txt

Let's save that out to an image too, and show it below

```python append:pydemo.py
image = Image.new(mode = "RGB", size = (200,200), color = "black")
draw = ImageDraw.Draw(image)
draw.text((10,10), msg, font=ImageFont.truetype('arial.ttf', 22), fill=(255,255,255))
image.save("cow.png") 
```

show:cow.png
~~~

When you save the the file, mdnb converts that to

~~~
---
code: sh .sh sh
code: python .py "python -OO"
---

## Code Chunk Example

Some **Standard** Markdown

```sh output:bashdemo
echo "from the bash demo"
```

```show:bashdemo
from the bash demo
```

``` python source:pydemo.py
# start of the python example code
from cowpy import cow
import text_to_image
from PIL import Image, ImageDraw, ImageFont
from resizeimage import resizeimage
import os
```

We can continue an explanation, and then add more code to a source file as we build our explanation.

```python append:pydemo.py output:pydemo.txt
msg = cow.Small().milk("mdnb!")
print(msg)
```

We can use the `show:file` shortcut directly; it will be replaced for us.

```show:pydemo.txt
 _______
< mdnb! >
 -------
      \   ,__,
       \  (oo)____
          (__)    )\
           ||--|| *
```

Let's save that out to an image too, and show it below

```python append:pydemo.py
image = Image.new(mode = "RGB", size = (200,200), color = "black")
draw = ImageDraw.Draw(image)
draw.text((10,10), msg, font=ImageFont.truetype('arial.ttf', 22), fill=(255,255,255))
image.save("cow.png") 
```

![cow.png](cow.png)
~~~

## Compiling

```sh
git clone https://github.com/JorySchossau/markdownNotebook
cd markdownNotebook
nim c mdnb
```
Done!

## Supported Commands

```
* CommonMark supported
* both code fences supported (```) and (~~~)

YAML Header Commands
* `code: id ext command
  id - the markdown language identifier you want to support in this file
  ext - the file extension of this filetype, used when saving source files
  command - the command to run for this filetype
    Use `$1` as a placeholder for the source filename without its extension
    (e.g. `g++ -o $1.out $1.cpp && ./$1.out`). When `$1` is absent, the source
    filename is appended to the command instead.

Code Fence Commands
* `source` - Run this block, autogenerate source filename, ignore output
* `source:filename` - Run this block, defining `filename` as the *entire* source for that file. If several cells name the same file with `source:`, the last one in document order wins (each overwrites).
* `append:filename` - Run this block, *appending* its content to `filename`, so several cells spread through the prose can all contribute to one source file. `source:` and `append:` are mutually exclusive within a single cell.
* `output:filename` - Run this block, saving output to `filename`, autogenerate source filename if `source`/`append` unspecified
* `inputs:filename` or `inputs:f1,f2,f3` - declare one or more (comma-separated, no spaces) files this cell consumes as inputs. The cell becomes a *dependency* of any cell that `output:`s one of those files: when such a producing cell changes, this cell is rerun too, even if its own source is unchanged. Dirtiness propagates transitively, so chains of `inputs:`→`output:` relationships all rebuild. (`inputs:` files are never written by mdnb — they are pure inputs.)
* `timeout:N` - per-cell execution timeout in seconds. If a cell is still running `N` seconds after it was launched, mdnb kills it and writes a notice (naming the limit that was hit) into its `output:` file and any matching `show:` cell, so you can see what happened and why. If `timeout:` is unspecified the default is 5 seconds. Set a larger value (e.g. `timeout:120`) for cells you know are long-running. Like any killed cell, `[k]`/`timeout:` terminate mdnb's shell wrapper; grandchildren the cell spawned may linger.
* `trim:head,N` / `trim:tail,N` - controls how much of a file's contents mdnb reads back *into the markdown* when displaying it. It is a **read-side / display** concern, not a write-side one: the file on disk is never altered or truncated by `trim:` — only the view shown in a `show:` block is bounded. The file is *streamed* line-by-line through the trim window, so an enormous file is never read fully into memory: `head` keeps the first `N` lines then stops reading; `tail` keeps a rolling buffer of the last `N` lines. The window applies wherever mdnb pulls a file into the markdown — both an explicit `show:filename` block and a bare `show:filename` shortcut. It can be declared on either the producing cell (its `output:` file's contents) or on the `show:` block itself; the `show:` block's own `trim:` wins, otherwise the producer cell's `trim:` is used, otherwise the default `trim:head,50`. When lines are actually dropped, a one-line footer is appended so you can see that truncation happened: `tail` names the mode, limit, and exact count cut; `head` names the mode and limit (it reports "further content truncated" without a count, since counting would require reading the whole file, which the streaming design avoids). A no-op (no footer) when the content already fits. Does not apply to mdnb-authored notices (timeout-kill, `(please wait)`).
* `show:filename` - display contents of file in block

Asynchronous execution state field
* `[s]` / `[r]` / `[x]` / `[k]` - an optional single-char field in `[ ]` placed right after the language id in the info string, e.g. `` ```python [x] source:foo.py ``. It controls manual execution and reports run state. With no field, a code cell auto-runs when it is dirty (its source/output file is missing/changed, or a cell whose output it consumes changed) — the default, unchanged behavior. The states:
  - `s` = stopped — the cell will not auto-run even if dirty; set `x` to run it.
  - `r` = running — set by mdnb while the cell's process is in flight (don't type this yourself).
  - `x` = execute — force the cell to run now, even if it isn't dirty; mdnb flips it to `r` while running, then `s` when done.
  - `k` = kill — terminate a currently-running cell; mdnb kills it and flips the state to `s`.
  Cells run as non-blocking subprocesses, so a long-running cell does not block the watcher from parsing further saves (or other files' saves). Because mdnb runs each cell through the shell, killing a cell terminates mdnb's shell wrapper; grandchildren the cell spawned may linger until they exit on their own.

Special Supported Language
* `raw` - may be used as the language of a code block, indicating no command to run, save to output if specified

Non-Code Fence Commands
* `show:filename` - replace this text with a markdown hyperlink to `filename` if image, or a codeblock if not an image
* `:clean` - on a line of its own. When mdnb next processes the file, this line is removed, every generated source and output file for the code cells in this file is deleted, and all cells are rerun from scratch. Use it to force a full fresh build; a normal save only reruns cells whose source or output is missing or would change.
```

## To-Do

The smaller-scope and architectural items that are ready to work on but are not
part of the core "Planned features" roadmap below.

- [x] Reimplement / Cleanup
- [x] Make non-code fence `show` command extension-aware and do the right thing
- [x] Make md filename part of temp filenames
- [x] **Modernize for current Nim** — the code is old relative to the latest compiler version; update to modern idioms.
- [x] **Memory model rewrite** — replace the `ptr ptr string` manual memory scheme with reallocated real strings. Currently, if the file content outgrows its allocated buffer, we must reallocate, copy, and free. This is the right fix but architectural.
- [x] **`$1` substitution in runtime commands** — allow variables like `g++ -o $1.out $1.cpp && ./$1.out` so compiled languages work cleanly.
- [x] **Position cache for unchanged files** — cache the locations of codeblock starts so that if a file hasn't been edited since the last parse, mdnb can use cached positions to write outputs without re-scanning. If the file has been modified, fall back to full PEG parsing.

### Planned features

These features have been agreed as the next work. They are grouped by priority.

**Tier 1 — core workflow**
- [x] Allow mutually exclusive `source:` vs `append:` codeblock commands. A cell with `source:filename` defines the single source file for its content (if several cells name the same file, the last one wins). A cell with `append:filename` instead appends its content to the named source file, so several cells spread through the prose can all contribute to one source file. A cell must use exactly one of `source:` / `append:` (not both). This is the supported way to build up a program across multiple prose-separated blocks without persistent kernel state.

**Tier 2 — reliability**
- [x] Only act on saves that are at least 1 second apart. If a save arrives less than 1s after the last processed save for that file, ignore it (debounce). Polling every 500ms stays; we will keep using mtime polling rather than native inotify/FSEvents watchers because they are system-limited and mdnb is cross-platform.
- [x] Build a cell call-dependency graph. A cell is considered dirty (and rerun) when a cell whose output it consumes changes, not only when its own source or output file is missing. A cell declares what it consumes via `inputs:<files>` (a comma-separated list, no spaces); it depends on any cell that `output:`s one of those files, and dirtiness propagates transitively through such chains. (`inputs:` is the dependency-input signal because mdnb never writes a cell's input files — they're pure inputs — whereas a cell's own `source:`/`output:` are files it *writes*.) Changing cell A invalidates cells that depend on A's output.
- [x] Implement asynchronous multithreaded execution so that a long-running cell does not block the watcher from parsing further saves. Introduce a new `[ ]` state field after the lang_name/id in the info string: states are `s`=stopped / `r`=running, and user can set `x`=execute / `k`=kill to control state. Cells run as non-blocking subprocesses (reaped on later watch cycles), so a long-running cell no longer holds up the watcher. Dirty-driven auto-run stays the default for cells with no `[ ]` field, so existing notebooks keep working unchanged.
- [x] Add a `timeout:N` codeblock command to set a per-cell timeout in N seconds. If a cell exceeds its timeout it should be killed. If `timeout:` is unspecified, default to 5 seconds. If killed, then the output should go to the output file for that codeblock that this happened and what the timeout limit was, so the user can see what and why.
- [ ] **Drain the output pipe while a cell runs, not only after it exits.** Today mdnb captures a cell's stdout via the OS pipe returned by `startProcess`, but it reads that pipe only in `reapFinished` — i.e. *after* `peekExitCode` reports the process has exited. The OS pipe buffer is tiny (~64 KB on Linux; up to ~1 MB). Any cell whose captured output exceeds that size fills the buffer, and the producer then **blocks** writing to a full pipe — it can never exit, so `reapFinished` is never reached, so the pipe is never read. The cell hangs until the per-cell `timeout:` (default 5 s) kills it, and the user sees `(mdnb killed this cell: exceeded timeout:Ns)` instead of their output. This silently defeats large-output capture (and the `trim:` window, which only ever sees the timeout-kill notice). Confirmed pre-existing — reproducible with `seq 1 1000000` as a cell body. **Suggested fix:** drain the pipe continuously while the cell is still running, so the producer never blocks. The recommended approach is to read available bytes off `Running.p.outputStream` on every `pollRuns` cycle into a per-cell accumulator (a non-blocking read loop that stops when the pipe is momentarily empty), then trim/write the accumulated output on the cycle where the process finally exits — this reuses the existing poll cadence and the streaming `readTrimmed` window with minimal new machinery. Alternatives considered: (a) a dedicated draining thread per cell launched in `startRun` and joined in `reapFinished` — cleaner separation but adds threading/synchronization complexity and a thread per running cell; (b) abandon pipe capture entirely and have the cell command redirect stdout straight to its `output:` file via the shell (`> file`, with `2>&1` to keep `poStdErrToStdOut` semantics), so mdnb reads the file in `reapFinished` — simplest and sidesteps the pipe buffer completely, but changes the capturing model and how stderr is merged. Whichever route, the drain must feed the existing `trim:head,N` / `trim:tail,N` streaming window so large outputs stay bounded in memory. Touches: `pollRuns`, `reapFinished`, and the `Running` record (an output accumulator field) in `mdnb_run.nim`.

**Tier 3 — usability**
- [x] Surface execution status in the output, e.g. for each run: which cell, the system command, the exit code, and how long it took. Add this as debug/verbose output alongside the existing run. Gated on the new `-v` / `--verbose` flag so a normal run is unchanged; with it, mdnb prints one line per launched cell (cell id, resolved command, timeout) and one line per finished/killed cell (cell id, command, exit code or kill reason, wall-clock duration) to stdout.
- [x] Add a `trim:head,N` and `trim:tail,N` codeblock command to bound how much of a file mdnb reads back into the markdown when displaying it (`show:` blocks and bare `show:file` shortcuts). Default to `trim:head,50` so large files do not burden the source file or the mdnb server; this default applies when no `trim:` is given. The file is streamed line-by-line through the trim window, so memory use scales with `N`, not with the file size (the first `N` lines for `head`, a rolling buffer of the last `N` for `tail`). This is a **read-side / display** concern: the on-disk file is never truncated — only the view shown in the markdown is bounded. The window may be set on the `show:` block itself or on the producing cell (whose `output:` file is being shown); the show block's own `trim:` wins, then the producer's, then the default. When lines are actually dropped, a one-line footer naming the mode and limit is appended; `tail` also names the exact count cut, while `head` reports "further content truncated" without a count (counting would require reading the whole file, which the streaming design avoids). A no-op when the content already fits; does not apply to mdnb-authored notices.
- [ ] Report errors on non-zero exit codes. When a system command does not exit cleanly, show the error in the resulting file so it will be displayed if the user created a `show:file` block for that output.

### Decisions recorded (not to do)
- Do **not** inline rich output by default. By default we should not show output; output only appears where the user explicitly requests it via `show:` / `output:`.
- Do **not** add native file watchers (inotify/FSEvents). Polling is fine and keeps mdnb cross-platform.
- Keep the current `:clean` behavior (documented above). No per-cell clear for now.
- Keep running cells in the current working directory; cells are responsible for their own environment variables if needed.
- No output-stripping/export pipeline, no multi-file project config, no shared cross-file runtimes for now.

## Bugs

Thar be bugs! Probably. Please file an issue if you find any.
