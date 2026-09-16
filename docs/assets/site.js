(() => {
  'use strict';

  // A deliberately small illustration, not a port of the native macro engine.
  // No clipboard, storage, microphone, or network access is used by this demo.
  const editor = document.querySelector('#demo-editor');
  const status = document.querySelector('#demo-status');
  const controls = document.querySelector('.demo-controls');
  const reset = document.querySelector('#demo-reset');
  if (!(editor instanceof HTMLTextAreaElement) || !status || !controls || !reset) return;

  const initialText = 'Hi Alex,\n\nThanks for the conversation today.\n\n';
  const snippets = new Map([
    [';sig', () => 'Best,\nSam\nProduct designer'],
    [';meet', () => 'I’ll send a short recap and next steps after our meeting.'],
    [';date', () => new Intl.DateTimeFormat(undefined, { dateStyle: 'long' }).format(new Date())]
  ]);
  let composing = false;

  const expand = () => {
    if (composing || editor.selectionStart !== editor.selectionEnd) return;
    const caret = editor.selectionStart;
    const before = editor.value.slice(0, caret);
    for (const [trigger, replacement] of snippets) {
      const start = caret - trigger.length;
      if (!before.endsWith(trigger) || (start > 0 && !/\s/.test(before[start - 1]))) continue;
      const result = replacement();
      if (editor.value.length - trigger.length + result.length > editor.maxLength) {
        status.textContent = 'Demo is full. Reset or shorten your note to keep trying.';
        return;
      }
      editor.setRangeText(result, start, caret, 'end');
      status.textContent = `${trigger} expanded. Keep typing, or try another.`;
      return;
    }
  };

  editor.value = initialText;
  controls.hidden = false;
  reset.hidden = false;
  editor.addEventListener('compositionstart', () => { composing = true; });
  editor.addEventListener('compositionend', () => { composing = false; expand(); });
  editor.addEventListener('input', (event) => {
    if (event instanceof InputEvent && (event.isComposing || event.inputType.startsWith('delete'))) return;
    expand();
  });
  controls.querySelectorAll('button[data-snippet]').forEach((button) => {
    button.addEventListener('click', () => {
      const trigger = button.getAttribute('data-snippet');
      if (!trigger || !snippets.has(trigger)) return;
      const start = editor.selectionStart;
      const end = editor.selectionEnd;
      const prefix = start > 0 && !/\s/.test(editor.value[start - 1]) ? '\n\n' : '';
      const insertion = prefix + trigger;
      if (editor.value.length - (end - start) + insertion.length > editor.maxLength) {
        status.textContent = 'Demo is full. Reset or shorten your note to keep trying.';
        return;
      }
      editor.setRangeText(insertion, start, end, 'end');
      editor.focus({ preventScroll: true });
      expand();
    });
  });
  reset.addEventListener('click', () => {
    editor.value = initialText;
    editor.setSelectionRange(initialText.length, initialText.length);
    status.textContent = 'Reset. Type ;sig, ;meet, or ;date.';
    editor.focus({ preventScroll: true });
  });
  editor.setSelectionRange(initialText.length, initialText.length);
})();
