# DevType Macro & Template Reference

DevType features a versatile dual template engine that natively parses both **Mustache** (`{{...}}`) and **TextExpander** (`%...%`) syntaxes. You can use either style or combine them within your snippets.

---

## 📑 Table of Contents
1. [Mustache Macro Syntax (`{{...}}`)](#1-mustache-macro-syntax-)
2. [TextExpander Macro Syntax (`%...%`)](#2-textexpander-macro-syntax-)
3. [Date & Time Formatting Tokens](#3-date--time-formatting-tokens)
4. [Date Arithmetic (Offsets)](#4-date-arithmetic-offsets)
5. [Inline Math Calculations (`{{calc:...}}`)](#5-inline-math-calculations-calc)
6. [Generated Values (UUID / Random / Counter)](#6-generated-values-uuid--random--counter)
7. [Case Transforms](#7-case-transforms)
8. [Real-World Snippet Recipes](#8-real-world-snippet-recipes)

---

## 1. Mustache Macro Syntax (`{{...}}`)

### Date & Time Macros
| Macro Tag | Output Example | Description |
|---|---|---|
| `{{date}}` | `Aug 16, 2026` | Current date in the localized medium style |
| `{{date:iso}}` | `2026-08-16` | ISO 8601 preset |
| `{{date:us}}` | `08/16/2026` | US preset (`MM/dd/yyyy`) |
| `{{date:eu}}` | `16/08/2026` | European preset (`dd/MM/yyyy`) |
| `{{date:full}}` | `Sunday, August 16, 2026` | Full localized long date |
| `{{date:yyyy-MM-dd HH:mm}}` | `2026-08-16 21:05` | Custom Unicode date pattern |
| `{{date:iso:+1d}}` | `2026-08-17` | Preset/pattern plus a relative offset (see §4) |
| `{{time}}` | `9:05:32 PM` | Current localized time |

All 16 named presets: `us`, `uslong`, `iso`, `eu`, `full`, `long`, `medium`, `short`, `datetime`, `time`, `timeshort`, `time24`, `weekday`, `monthyear`, `day`, `year`. Any spec that is not a preset name is treated as a raw `DateFormatter` pattern.

### Dynamic System Macros
| Macro Tag | Description |
|---|---|
| `{{clipboard}}` | Injects the plaintext contents of your current macOS pasteboard. Clipboard text is preserved literally, including template-shaped text such as `{{cursor}}`; those bytes are never interpreted as additional macros. |
| `{{cursor}}` | Repositions the text insertion caret at this exact spot after expansion. If several appear, **the first wins**. |
| `{{snippet:trigger_name}}` | Dynamically embeds another snippet. Nesting is capped at depth 10 and a global budget (10,000 substitutions / 2 MB output per pass) — over-budget references are left as literal text rather than hanging the engine. Secret snippets are never resolved through nesting. |

### Math Evaluation
| Macro Tag | Output Example | Description |
|---|---|---|
| `{{calc: 12 * 8}}` | `96` | Evaluates inline arithmetic expressions |
| `{{calc: (50 - 14) / 4}}` | `9` | Parentheses, floating-point math, standard operators |

A malformed or oversized expression (over 64 characters or 48 tokens) is left **as its literal tag text** instead of being silently deleted from the expansion.

---

## 2. TextExpander Macro Syntax (`%...%`)

DevType provides seamless compatibility with TextExpander snippet templates:

### Interactive Fill-in Fields
When a snippet containing fill-in fields expands, DevType presents an interactive popup sheet to enter variable values:

```text
Hi %filltext:name=Customer Name%,

Thank you for contacting support regarding ticket #%filltext:name=Ticket ID%.
We are actively investigating this and will reply by %date:us%.

Best regards,
%filltext:name=Agent Name:default=Support Team%
```

| Macro Tag | Description |
|---|---|
| `%filltext:name=X%` | Single-line fill-in field (`:default=Y` supported) |
| `%fillarea:name=X%` | Multi-line fill-in field (`width=`/`height=` hints are tolerated and survive nesting) |
| `%fillpopup:name=X:Option A:Option B:default=Option A%` | Drop-down popup field; every extra segment is one option |
| `%fillpart:name=X:default=yes% … %fillpartend%` | Optional section toggled from the fill-in sheet (`default=no` starts off). Sections nest. |

### Caret & Keystroke Control
| Macro Tag | Description |
|---|---|
| `%\|` | Sets the final cursor caret position (first marker wins) |
| `%key:enter%` / `%key:return%` | Posts a Return keystroke after text insertion |
| `%key:tab%` | Posts a Tab keystroke after insertion |
| `%key:esc%` / `%key:escape%` | Posts an Escape keystroke after insertion |
| `%key:space%` | Posts a Space keystroke after insertion |
| `%clipboard` | Injects literal clipboard text (like `{{clipboard}}`; matched non-greedily, so `%clipboardless` stays literal) |

Key names keep their author casing — `%key:Enter%` round-trips through nesting unchanged.

### Nesting & Structure
| Macro Tag | Description |
|---|---|
| `%snippet:abbrev%` | Embeds another snippet by its trigger (same depth/budget limits as `{{snippet:…}}`; references resolve in place without disturbing sibling macros) |
| `%case:upper% … %caseend%` | Case-transforms everything between the markers (see §7); an unbalanced block applies to the rest of the output |

### Escaping & Unknown Tags
- Inside any macro body, `%%` is an escaped literal `%` — so `%filltext:name=D:default=50%%off%` yields the default `50%off`.
- Unrecognized `%…%` sequences (e.g. URL-encoded text like `%EC%B0%A8`) are left exactly as written.

---

## 3. Date & Time Formatting Tokens

When specifying custom date patterns in `{{date:PATTERN}}` or `%date:PATTERN%`, use standard Unicode format tokens:

| Token | Description | Example |
|---|---|---|
| `yyyy` | 4-digit Year | `2026` |
| `yy` | 2-digit Year | `26` |
| `MMMM` | Full Month Name | `August` |
| `MMM` | Short Month Name | `Aug` |
| `MM` | 2-digit Month | `08` |
| `dd` | 2-digit Day of Month | `16` |
| `d` | 1- or 2-digit Day | `16` |
| `EEEE` | Full Day of Week | `Sunday` |
| `EEE` | Short Day of Week | `Sun` |
| `HH` | 24-hour Hour (00–23) | `21` |
| `hh` | 12-hour Hour (01–12) | `09` |
| `mm` | Minute (00–59) | `05` |
| `ss` | Second (00–59) | `30` |
| `a` | AM / PM marker | `PM` |
| `ZZZZ` | Timezone Offset | `GMT-05:00` |

---

## 4. Date Arithmetic (Offsets)

Any date spec accepts a trailing offset, and TextExpander's `%@…%` shorthand works too:

| Syntax | Meaning |
|---|---|
| `{{date:+1d}}` | Tomorrow (offset-only specs render as the localized medium date) |
| `{{date:iso:+1d}}` | ISO-formatted tomorrow |
| `%date:us:-2w%` | Two weeks ago, US format |
| `%@+1D%` | TextExpander-style date math |
| `+1y-3M` | Compound offsets combine freely |

Units: `y`/`Y` years · `M` months (**uppercase**) · `w`/`W` weeks · `d`/`D` days · `h`/`H` hours · `m` minutes (**lowercase**) · `s`/`S` seconds.

Arithmetic goes through calendar day/month/year addition — never raw seconds — so DST transitions and variable month lengths behave correctly.

---

## 5. Inline Math Calculations (`{{calc:...}}`)

The `SafeMathParser` evaluates mathematical expressions with strict safety bounds (no eval, no shell execution, zero security risk).

### Supported Operators
- `+` (Addition, including unary minus like `-5 + 10`)
- `-` (Subtraction)
- `*` (Multiplication)
- `/` (Division — dividing by zero leaves the tag as literal text rather than emitting infinity)
- `%` (Modulo / Remainder)
- `^` (Exponentiation)
- `(` and `)` (Grouping and operator precedence)

### Examples
- `{{calc: 100 + 15}}` → `115`
- `{{calc: 2^10}}` → `1024`
- `{{calc: (10 + 20) * 5}}` → `150`
- `{{calc: 7 % 4}}` → `3`

Whole-number results print without a decimal point; fractional results keep theirs.

---

## 6. Generated Values (UUID / Random / Counter)

Both syntaxes generate values during preparation. Each occurrence receives its own value. Preparation and the fill-in render share an explicit operation context, so a slow interaction retains its UUIDs, random choices, date, clipboard snapshot, and reserved counter values. Two separate expansions receive separate values even when they happen immediately after each other.

### UUID
| Tag | Output Example | Description |
|---|---|---|
| `%uuid%` / `{{uuid}}` | `E621E1F8-C36C-495A-93FC-0C247A3E6E5F` | Standard upper-case UUID |
| `%uuid:lower%` | `e621e1f8-c36c-495a-93fc-0c247a3e6e5f` | Lower-cased |
| `%uuid:short%` | `E621E1F8` | First 8 characters |
| `%uuid:compact%` | `E621E1F8C36C495A93FC0C247A3E6E5F` | Dashes removed |

### Random (`%random:SPEC%` / `{{random:SPEC}}`)
| Spec | Result |
|---|---|
| *(empty)* | Integer 0–99 |
| `1-100` | Integer in the inclusive range |
| `yes\|no\|maybe` | One of the pipe-separated choices |
| `hex:8` | 8 lowercase hex characters |
| `alnum:12` | 12 alphanumeric characters |
| `digits:6` | 6 digits |
| `letters:8` | 8 lowercase letters |

### Counter (`%counter:name%` / `{{counter:name}}`)
Persistent named counters that increment on each expansion. An optional signed step changes the increment (`%counter:ticket:+5%`, `%counter:countdown:-1%`). Counters persist across launches. A value is reserved once per occurrence in an expansion. Cancelling after preparation can leave a gap; reserved values are not rolled back because output may already have escaped. Counter mutations and their persisted snapshots are serialized.

---

## 7. Case Transforms

Transform any literal text, fill-in value, or nested snippet output:

| Mustache | TextExpander block | Result for `hello world` |
|---|---|---|
| `{{upper:…}}` | `%case:upper% … %caseend%` | `HELLO WORLD` |
| `{{lower:…}}` | `%case:lower% … %caseend%` | `hello world` |
| `{{title:…}}` | `%case:title% … %caseend%` | `Hello World` |
| `{{sentence:…}}` | `%case:sentence% … %caseend%` | `Hello world` |

Friendly aliases work in the TE form (`uppercase`/`uc`, `lowercase`/`lc`, `titlecase`/`capitalize`, `sentencecase`). Mustache transforms nest innermost-first and never fold a `{{cursor}}` marker sitting inside them; case blocks also wrap fill-ins cleanly:

```text
Dear {{upper:%filltext:name=Name%}},
```

---

## 8. Real-World Snippet Recipes

### 🛠️ Git Conventional Commit
- **Trigger**: `:gcommit`
- **Body**:
```text
feat({{cursor}}): 

Closes #
```

### 📅 Daily Standup Markdown Note
- **Trigger**: `:standup`
- **Body**:
```markdown
# Daily Standup — {{date:yyyy-MM-dd}}

### ✅ Yesterday
- {{cursor}}

### 🎯 Today
- 

### 🚧 Blockers
- None
```

### 🆔 Support Ticket Auto-increment
- **Trigger**: `:ticket`
- **Body**:
```text
Ticket #{{counter:tickets}} — opened {{date:us}}, follow-up due {{date:us:+3d}}
Reference ID: {{uuid:short}}
```

### ✉️ Quick Meeting Follow-Up
- **Trigger**: `:followup`
- **Body**:
```text
Hi %filltext:name=Name%,

Great speaking with you today regarding %filltext:name=Topic%.

As discussed, next steps:
1. {{cursor}}
2. Target completion: {{date:full}}

Best regards,
Alex
```

> [!TIP]
> `%fillpopup:name=Priority:High:Medium:Low:default=Medium%` renders a drop-down in the same sheet — handy for the topic line above.

### 💻 Markdown Code Block with Clipboard
- **Trigger**: `:mdcode`
- **Body**:
````markdown
```swift
{{clipboard}}
```
{{cursor}}
````

## Rendering boundaries

Clipboard text, fill-in values, and generated values remain literal data through both syntaxes. For example, copying `{{counter:invoice}}` and expanding `%clipboard` inserts those characters without advancing a counter. A surrounding case transform can change their letter case without interpreting them as syntax.

Cursor markers remain anchors until all substitutions and case transforms finish. The first cursor position in the final text wins across both syntaxes. `{{upper:abc}}%|x` produces `ABCx` with the caret before `x`; length-changing Unicode transforms and emoji use final UTF-16 coordinates.

Rendering is bounded to 1,048,576 UTF-16 units, 4,096 tokens/operations, and a cumulative transformation-work budget. The existing nested-reference depth/substitution/output limits also apply. A rendering-budget failure or overlapping transform structure refuses the expansion with an explicit error; it never sends partial text or trailing keys. Unknown tags and malformed math expressions retain their existing literal behavior.
