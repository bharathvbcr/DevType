# DevType Macro & Template Reference

DevType features a versatile dual template engine that natively parses both **Mustache** (`{{...}}`) and **TextExpander** (`%...%`) syntaxes. You can use either style or combine them within your snippets.

---

## 📑 Table of Contents
1. [Mustache Macro Syntax (`{{...}}`)](#1-mustache-macro-syntax-)
2. [TextExpander Macro Syntax (`%...%`)](#2-textexpander-macro-syntax-)
3. [Date & Time Formatting Tokens](#3-date--time-formatting-tokens)
4. [Inline Math Calculations (`{{calc:...}}`)](#4-inline-math-calculations-calc)
5. [Real-World Snippet Recipes](#5-real-world-snippet-recipes)

---

## 1. Mustache Macro Syntax (`{{...}}`)

### Date & Time Macros
| Macro Tag | Output Example | Description |
|---|---|---|
| `{{date}}` | `8/16/2026` | Current date formatted in system default locale |
| `{{date:iso}}` | `2026-08-16` | ISO 8601 standard date format |
| `{{date:us}}` | `08/16/2026` | US standard date format (`MM/dd/yyyy`) |
| `{{date:eu}}` | `16/08/2026` | European standard date format (`dd/MM/yyyy`) |
| `{{date:full}}` | `Sunday, August 16, 2026` | Full localized long date |
| `{{date:yyyy-MM-dd HH:mm}}` | `2026-08-16 21:05` | Custom pattern using Unicode date tokens |
| `{{time}}` | `9:05 PM` | Current localized time |

### Dynamic System Macros
| Macro Tag | Description |
|---|---|
| `{{clipboard}}` | Injects the plaintext contents of your current macOS pasteboard |
| `{{cursor}}` | Automatically repositions the text insertion caret at this exact spot after expansion |
| `{{snippet:trigger_name}}` | Dynamically embeds the content of another snippet (supports up to 10 nested levels) |

### Math Evaluation
| Macro Tag | Output Example | Description |
|---|---|---|
| `{{calc: 12 * 8}}` | `96` | Evaluates inline arithmetic expressions |
| `{{calc: (5000 / 12) * 1.05}}` | `437.5` | Supports parentheses, floating-point math, and standard operators |

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

### Caret & Keystroke Control
| Macro Tag | Description |
|---|---|
| `%|` | Sets the final cursor caret position |
| `%key:enter%` | Posts an `Enter` / `Return` keystroke after text insertion |
| `%key:tab%` | Posts a `Tab` keystroke after text insertion |
| `%key:esc%` | Posts an `Escape` keystroke after text insertion |
| `%clipboard` | Injects the clipboard text |

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

## 4. Inline Math Calculations (`{{calc:...}}`)

The `SafeMathParser` evaluates mathematical expressions with strict safety bounds (no eval, no shell execution, zero security risk).

### Supported Operators
- `+` (Addition)
- `-` (Subtraction)
- `*` (Multiplication)
- `/` (Division)
- `%` (Modulo / Remainder)
- `^` (Exponentiation)
- `(` and `)` (Grouping and operator precedence)

### Examples
- `{{calc: 100 * 1.15}}` → `115.0`
- `{{calc: 2^10}}` → `1024`
- `{{calc: (10 + 20) * 5}}` → `150`

---

## 5. Real-World Snippet Recipes

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

### 💻 Markdown Code Block with Clipboard
- **Trigger**: `:mdcode`
- **Body**:
````markdown
```swift
{{clipboard}}
```
{{cursor}}
````
