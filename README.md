<h1 align="center">Laesesalen</h1>

<p align="center"><strong>Drop a Chinese document in. Read it in English. Nothing leaves the Mac.</strong></p>

<p align="center"><sub>The document translator in the Babelstaarnet toolkit.</sub></p>

Laesesalen — *the reading room* — translates Simplified Chinese documents into
English on your own Mac. PDFs, photographs of pages, scans. No account, no
upload, no server, and by default nothing to install: the models it uses are
the ones that came with macOS.

## The idea

**Two readers, not one.** A character recognizer and a vision-language model
read every page independently, and their failure modes do not overlap — Vision
confuses 未 and 末; a language model does not, because the sentence only works
one way. The app can carry its own vision model and run it in this process on
the Mac's GPU, so the second reader does not depend on what Apple has decided
this Mac is eligible for. Where they agree, that is evidence. Where they disagree, the app says
so and shows you both readings rather than picking quietly. Where the PDF
carries its own text, neither of them has to guess.

**It reads the document before it translates a sentence of it.** A translator
shown one sentence at a time has to guess what kind of thing it is holding, and
it guesses again on the next sentence. 甲方 becomes "Party A" on page one and
"the first party" on page seven; both are correct on their own line, which is
why nothing catches it and why the result reads like two translations stapled
together. So the app reads first — a sample taken from across the document, not
off the front of it — and settles what this is, what has already happened, how
it should sound, and what its recurring terms will be called. Every sentence
after that is translated as part of something. Where a block disagrees with
what the document settled on, it is marked, because no model reading one
paragraph can see it.

**It looks names up instead of spelling them out.** 布洛芬 is ibuprofen.
Nothing in the characters says so — they spell out as "buluofen", which is how
Chinese borrowed the English word to begin with — so a translator working a
line at a time will sometimes write exactly that: a word that names no
medicine, in a sentence that reads perfectly, on a prescription somebody is
about to act on. Every other check in the app passes it. So before translating,
the app works out what field the document is from — medicine, law, engineering,
a letter — and asks what the things in it are already called: a drug's generic
name, a company's registered name, a hospital's own English name, a statute's
official title. A model that is not sure is told to say so, and the name is
then spelled out where you can see it rather than invented. Whatever it settles
is shown to you while it works and printed in the export, because a name is the
one decision here you can check without reading a word of Chinese.

**And it gives each sentence as much of the page around it as that sentence
needs — and no more.** Not all of it: a heading of four characters padded
with four hundred characters of surrounding prose is the reliable way to
make a small model translate the context instead of the block, and every
character in front of the block is time on somebody's laptop. So a sentence
that stands on its own is translated on its own, and one that cannot is
shown what it is missing — the line before it where it says 该方 or 上述, the
section under it where it is a heading, the column heading above it where it
is a cell in a table, across page breaks. The app records which of those
each block was given, and the side-by-side export shows it. Where the
context turns out to have been the problem — a block of figures that a small
model copies back instead of translating, which is a real and measured thing
— the mechanical check notices and the block is translated once more with
nothing around it.

**The app tells you what it is unsure about.** Every block carries a confidence
and a reason in plain words — "the readers disagreed — “未” against “末” — and
Vision OCR was chosen" — and the blocks that need a human are one click from
the rest of the document. A translation you cannot check is a translation you
have to trust; this one shows its working.

**Some mistakes cannot be caught by a model.** A second model reviewing the
first will approve a fluent paragraph whose figures changed, because it is
another language model with the same blind spots. So the review is mechanical
as well: dropped numbers, missing clauses, source text left untranslated,
repetition loops, the instructions you gave, any block that renames something
the rest of the document had already named, and any name that came back spelled
out in Pinyin are all checked without asking anyone.

**It asks before it guesses.** If something about the document has two
defensible translations — a term of art, a name that could be a person or a
company, a register that depends on who the document is for — it asks you, once,
before it starts. If it could not work out what field the document is from, it
asks that first, because that one answer decides what everything in the
document is called. "I'm not sure" is always an answer.

**Nothing leaves your Mac,** and that is a property of the code rather than a
promise. One module in the package can open a socket at all, and the only
address it can form is `127.0.0.1`. The app keeps the receipts and shows them
to you. See [PRIVACY.md](docs/PRIVACY.md).

## Install

Requires macOS 26 or newer.

```bash
git clone https://github.com/Sininliny/Babelstaarnet_Toolkit_DocTranslator.git
cd Babelstaarnet_Toolkit_DocTranslator
make install
```

That builds the app and puts it in **Applications**. A bundle you built was
never downloaded, so Gatekeeper has nothing to quarantine and there is no
"Open Anyway" step. Building needs only the Command Line Tools
(`xcode-select --install`).

### The app's own vision model

Laesesalen carries its own vision-language model, run on the Mac's GPU with
[MLX](https://github.com/ml-explore/mlx-swift) rather than relying on Apple
Intelligence being available. **It is included automatically whenever this Mac
can compile it** — `make app`, `make run` and `make install` all look for it.

What it needs is the `metal` compiler, which comes with **Xcode** rather than
with the Command Line Tools. Where that is missing the build says so, builds
the app without the engine, and *Settings → Models* inside that app says the
same thing rather than offering five models it cannot fetch. If Xcode is
installed but the Metal toolchain is not, run
`xcodebuild -downloadComponent MetalToolchain`.

```bash
make app-mlx     # insist on the engine; fail rather than build without it
make app-lean    # deliberately without it, which builds far faster
```

The model itself is fetched later, from inside the app, when you ask for it.

## Use

Drop a PDF, PNG, or JPG on the window — or ⌘O to choose one, or ⇧⌘V to
paste a page you have just screenshotted. Before you do, choose what you want
back:

| Mode | What you get |
| --- | --- |
| **The same document, in English** | A PDF that looks like the original — background, stamps, tables, letterhead — with the Chinese replaced in place. |
| **Just the text** | Plain text in reading order. Nothing to strip out. |
| **Side by side** | Both languages block by block, with what each reader saw and why each block scored as it did. |

Two things are worth setting before a document that matters:

- **The translation brief.** Anything you would tell a human translator —
  "keep personal names in Chinese", "this is a court filing, keep it formal".
  Particular words can be pinned: keep 王小明 as written, always render 公司 as
  "the Company". Pinned words are *checked* — if the English does not do what
  you asked, the block is marked.
- **Questions.** Leave these on and the app will ask up to three things about
  the document before translating. Turn them off in the brief.

## What it needs

Nothing, on a Mac with Apple Intelligence available. The engines it looks for:

| Role | Engine | Needs |
| --- | --- | --- |
| Reads the page | Apple Vision | Nothing. Part of macOS. |
| Reads it again | Laesesalen's own vision model | Xcode, for the Metal compiler — then one download from inside the app |
| Reads it again | Apple's on-device model | Apple Intelligence on, macOS 27 for images |
| Reads the document, settles disagreements, reviews, asks | Either of the above, or a dedicated text model | On a Mac with room to hold two models at once |
| Translates | Apple Translation | A one-time Chinese download, offered in the app |
| *(optional)* Anything above | A model server you run | Off by default; loopback only |

The app works with less than all of them and says which are missing and what
would fix each one. With only Vision and Apple Translation it still reads,
translates, and runs every mechanical check — it just has no second reader, no
reviewer, and no reading of the document as a whole, and the confidence scores
say exactly that.

### The app's own models

**How large a model you get is decided by the Mac, not by us.** Laesesalen's
own reader is a 4-bit Qwen vision model, and it comes in five sizes from 1.4
to 18.5 GB. The app asks the machine how much unified memory it has and offers
the largest one that fits with room to spare — a 2B on an eight-gigabyte
laptop, a 7B on sixteen, the 32B on a Mac with sixty-four. One default for
every Mac is wrong in both directions: it wastes most of a large machine while
a smaller model misreads figures, and on a small one it does not run slowly, it
swaps. You can override the choice; the app says what it picked and why.

**On a large Mac it will also use a second, text-only model** — a Qwen3 or
Qwen2.5 in the 4-to-30-billion range — for translating, reviewing, settling
disagreements and reading the document. On every other Mac the page reader does
that work too, which costs nothing extra: a vision-language model *is* a
language model with an image encoder on it. A second model is only worth its
second download and its second few gigabytes resident where both fit in memory
at once, so the app offers one only there.

**Everything it installs, it can uninstall.** *Settings → Models* (⌘,)
lists every model on the Mac with its size — including ones a previous version
of the app downloaded and this one no longer offers, which nothing else would
ever mention again — and removes any of them, or all the ones nothing is using,
in one press. The same from a terminal, and from a build made without the MLX
engine:

```bash
"/Applications/Laesesalen.app/Contents/MacOS/Laesesalen" --models
```

with `--clean-models` to remove what is unused and `--remove-model <id>` for
one. The weights live in `~/Library/Application Support/Laesesalen/Models`.

The download is the only moment this app talks to the internet, it happens
because someone pressed a button, and your document is not part of it: the
request is for a file by name. The app keeps the receipts and shows them under
the lock in the corner.

The optional model server is for the case none of that covers: a document a
small model reads badly, where you already run something larger. It speaks
Ollama's API or an OpenAI-compatible one, and the address it will accept can
only be this machine.

## Checking it yourself

```bash
make test
```

Runs the structural privacy check and the whole suite — the layout logic, the
reconciler, the agents end to end against fixtures, the integrity checks, the
translated page itself down to whether the rule between two columns survived,
and Apple Vision actually reading a page of rendered Chinese. No models, no
server, and no network: a fresh clone runs this.

The app will also run on one document without its window, which is how a
fault about a particular page gets checked again after a change:

```bash
"/Applications/Laesesalen.app/Contents/MacOS/Laesesalen" --translate page.pdf ./out
```

That writes all three exports beside each other and prints how many blocks
came back needing a human. `--engines` prints what every engine reports and
exits; `--models` prints what this Mac can hold and what has been downloaded.

A few more, for a build that has the app's own model. They need the weights,
so they are commands rather than part of the suite:

```bash
swift run --traits MLXEngine Checks --local-model      # it reads a page
swift run --traits MLXEngine Checks --full-run ./out   # the whole app, on a page
swift run --traits MLXEngine Checks --prompt-probe     # does it actually translate
```

---

**[How it works →](docs/HOW_IT_WORKS.md)** — the pipeline, the agents, and the
design rules behind them.
**[Privacy →](docs/PRIVACY.md)** — what the guarantee is and how it is enforced.
