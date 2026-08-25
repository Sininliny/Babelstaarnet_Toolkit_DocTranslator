<h1 align="center">Læsesalen</h1>

<p align="center"><strong>Drop a Chinese document in. Read it in English. Nothing leaves the Mac.</strong></p>

<p align="center"><sub>The document translator in the Babelstårnet toolkit.</sub></p>

Læsesalen — *the reading room* — translates Simplified Chinese documents into
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

**The app tells you what it is unsure about.** Every block carries a confidence
and a reason in plain words — "the readers disagreed — “未” against “末” — and
Vision OCR was chosen" — and the blocks that need a human are one click from
the rest of the document. A translation you cannot check is a translation you
have to trust; this one shows its working.

**Some mistakes cannot be caught by a model.** A second model reviewing the
first will approve a fluent paragraph whose figures changed, because it is
another language model with the same blind spots. So the review is mechanical
as well: dropped numbers, missing clauses, source text left untranslated,
repetition loops, and the instructions you gave are all checked without asking
anyone.

**It asks before it guesses.** If something about the document has two
defensible translations — a term of art, a name that could be a person or a
company, a register that depends on who the document is for — it asks you, once,
before it starts. "I'm not sure" is always an answer.

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

### With the app's own vision model

```bash
make app-mlx
```

This builds Læsesalen with [MLX](https://github.com/ml-explore/mlx-swift)
inside it, so the app runs its own vision-language model on the Mac's GPU
rather than relying on Apple Intelligence being available. It is the better
configuration and it costs more to build: MLX compiles Metal kernels, and the
`metal` compiler comes with **Xcode**, not the Command Line Tools. If Xcode is
installed but Metal is not, macOS will tell you to run
`xcodebuild -downloadComponent MetalToolchain`.

The model itself is fetched later, from inside the app, when you ask for it.

## Use

Drop a PDF, PNG, or JPG on the window. Before you do, choose what you want back:

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
| Reads it again | Læsesalen's own vision model | A build with `make app-mlx`, then one download from inside the app |
| Reads it again | Apple's on-device model | Apple Intelligence on, macOS 27 for images |
| Settles disagreements, reviews, asks | Either of the above | — |
| Translates | Apple Translation | A one-time Chinese download, offered in the app |
| *(optional)* Anything above | A model server you run | Off by default; loopback only |

The app works with less than all of them and says which are missing and what
would fix each one. With only Vision and Apple Translation it still reads,
translates, and runs every mechanical check — it just has no second reader and
no reviewer, and the confidence scores say exactly that.

Læsesalen's own model is a 4-bit Qwen2.5-VL, about 2.3 GB, fetched once from
Hugging Face and run on this Mac from then on. Your document is not part of
that download and never leaves the machine; the app keeps the receipts and
shows them under the lock in the corner. It can be removed again from the same
panel.

The optional model server is for the case neither of those covers: a document
a 3-billion-parameter model reads badly, where you already run something
larger. It speaks Ollama's API or an OpenAI-compatible one, and the address it
will accept can only be this machine.

## Checking it yourself

```bash
make test
```

Runs the structural privacy check and 199 assertions — the layout logic, the
reconciler, the agents end to end against fixtures, the integrity checks, and
Apple Vision actually reading a page of rendered Chinese. No models, no server,
and no network: a fresh clone runs this.

Two more, for a build that has the app's own model. Both need the weights, so
they are commands rather than part of the suite:

```bash
swift run --traits MLXEngine Checks --local-model      # it reads a page
swift run --traits MLXEngine Checks --full-run ./out   # the whole app, on a page
```

---

**[How it works →](docs/HOW_IT_WORKS.md)** — the pipeline, the agents, and the
design rules behind them.
**[Privacy →](docs/PRIVACY.md)** — what the guarantee is and how it is enforced.
