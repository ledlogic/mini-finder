// mf-actions.js
// Fetch-based actions: save, delete, colorized, cover, OCR detect name

// ── Quick colorized set on search results ────────────────────────────────────
async function setColorized(imageId, value, btn) {
  await fetch(`/images/${imageId}/colorized`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `value=${value}`
  });
  // Update active state on all three buttons in this card
  btn.closest('.colorized-btns').querySelectorAll('.btn-col-set').forEach(b => {
    b.classList.remove('btn-col-active');
  });
  btn.classList.add('btn-col-active');
}

// ── Colorized toggle ─────────────────────────────────────────────────────────
async function cycleColorized(imageId, currentState, btn) {
  // Cycle: unknown -> color -> grey -> unknown
  const next = { unknown: 'color', color: 'grey', grey: 'unknown' };
  const icons  = { color: '🎨', grey: '⬜', unknown: '◌' };
  const titles = {
    color:   'Colorized render (click to mark grey)',
    grey:    'Grey/uncolored (click to mark unknown)',
    unknown: 'Colorized? (unknown — click to set)'
  };
  const values = { color: 'true', grey: 'false', unknown: 'null' };

  const newState = next[currentState];
  btn.textContent = icons[newState];
  btn.title = titles[newState];
  btn.className = `btn-colorized btn-colorized-${newState}`;
  btn.onclick = () => cycleColorized(imageId, newState, btn);

  await fetch(`/images/${imageId}/colorized`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `value=${values[newState]}`
  });
}

// ── Set collection cover image ─────────────────────────────────────────────
async function setCover(collectionId, imageId, btn) {
  btn.disabled = true;
  btn.textContent = '…';
  try {
    const res = await fetch(`/collections/${collectionId}/set_cover`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: `image_id=${imageId}`
    });
    if (res.ok) {
      btn.textContent = '✓';
      btn.classList.add('btn-set-cover-done');
      // Reset other cover buttons in same collection
      document.querySelectorAll('.btn-set-cover-done').forEach(b => {
        if (b !== btn) {
          b.textContent = '⊙';
          b.classList.remove('btn-set-cover-done');
        }
      });
      setTimeout(() => {
        btn.textContent = '⊙';
        btn.classList.remove('btn-set-cover-done');
        btn.disabled = false;
      }, 2000);
    } else {
      btn.textContent = '✕';
      setTimeout(() => { btn.textContent = '⊙'; btn.disabled = false; }, 1500);
    }
  } catch(e) {
    btn.textContent = '✕';
    setTimeout(() => { btn.textContent = '⊙'; btn.disabled = false; }, 1500);
  }
}

// ── Delete image ─────────────────────────────────────────────────────────────
function deleteImage(id, filename, btn) {
  if (!confirm('Delete ' + filename + '\nThis will remove the file from disk. Are you sure?')) return;
  btn.disabled = true;
  btn.textContent = '…';
  fetch('/images/' + id + '/delete', { method: 'POST' })
    .then(function(resp) {
      if (resp.ok || resp.redirected) {
        // Remove the row from the DOM immediately
        var row = btn.closest('tr');
        // Also remove the preceding collection-header-row if this was the only image
        if (row) row.remove();
        // Reload to reflect accurate state
        window.location.reload();
      } else {
        alert('Delete failed (status ' + resp.status + ')');
        btn.disabled = false;
        btn.textContent = '🗑';
      }
    })
    .catch(function(err) {
      alert('Delete failed: ' + err);
      btn.disabled = false;
      btn.textContent = '🗑';
    });
}

// ── Save image row (replaces HTML form submit) ────────────────────────────────
function saveRow(id, ctx, btn) {
  var row = btn.closest('tr');
  if (!row) return;

  // Collect all named inputs/selects/textareas in this row
  var data = new FormData();
  row.querySelectorAll('input[name], select[name], textarea[name]').forEach(function(el) {
    if (el.type === 'checkbox') {
      data.append(el.name, el.checked ? el.value : '');
    } else {
      data.append(el.name, el.value);
    }
  });

  // Append context params (folder filter, flags etc)
  if (ctx) {
    ctx.split('&').forEach(function(pair) {
      var parts = pair.split('=');
      if (parts[0]) data.append(decodeURIComponent(parts[0]), decodeURIComponent(parts[1] || ''));
    });
  }

  btn.disabled = true;
  btn.textContent = '…';

  fetch('/images/' + id, { method: 'POST', body: data, headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' } })
    .then(function(resp) {
      btn.disabled = false;
      btn.textContent = '✓';
      if (resp.ok || resp.redirected) {
        btn.style.background = 'var(--accent)';
        row.classList.add('row-tagged');
        row.classList.remove('row-untagged');
        // Reset dirty-state baseline so button doesn't re-red
        if (row._dirtyOriginals && row._dirtyInputs) {
          row._dirtyInputs.forEach(function(inp) {
            row._dirtyOriginals[inp.name] = inp.value;
          });
        }
        // If an xref was assigned or removed, reload so sort order and secondary display updates
        var xrefCheckbox = row.querySelector('input[name="is_secondary"]');
        var xrefSelect   = row.querySelector('select[name="primary_image_id"]');
        if (xrefCheckbox && (xrefCheckbox.checked || xrefSelect && xrefSelect.value)) {
          window.location.reload();
          return;
        }
      } else {
        alert('Save failed (status ' + resp.status + ')');
      }
    })
    .catch(function(err) {
      btn.disabled = false;
      btn.textContent = '✓';
      alert('Save failed: ' + err);
    });
}

// ── OCR detect name for a single image ───────────────────────────────────────
function detectName(id) {
  var btn = document.getElementById('ocr-btn-' + id);
  if (btn) { btn.disabled = true; btn.textContent = '⏳'; }

  fetch('/images/' + id + '/detect_name', {
    headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
  })
  .then(function(resp) { return resp.json(); })
  .then(function(data) {
    if (btn) { btn.disabled = false; btn.textContent = '💡'; }

    if (data.error) {
      alert('OCR: ' + data.error);
      return;
    }

    var row   = btn ? btn.closest('tr') : null;
    var input = row ? row.querySelector('input[name="mini_name"]') : null;

    if (data.suggested_name && input) {
      // If name field is empty, fill it directly; otherwise show as suggestion
      if (!input.value.trim()) {
        input.value = data.suggested_name;
        input.dispatchEvent(new Event('input'));
      } else {
        // Insert a temporary suggestion button
        var existing = row.querySelector('.btn-ocr-suggestion');
        if (existing) existing.remove();
        var sug = document.createElement('button');
        sug.type = 'button';
        sug.className = 'btn-suggestion btn-ocr-suggestion';
        sug.textContent = '✦ ' + data.suggested_name;
        sug.onclick = function() {
          input.value = data.suggested_name;
          input.dispatchEvent(new Event('input'));
          sug.remove();
        };
        input.insertAdjacentElement('afterend', sug);
      }
    } else {
      alert('OCR: no name detected in this image');
    }
  })
  .catch(function(err) {
    if (btn) { btn.disabled = false; btn.textContent = '💡'; }
    alert('OCR failed: ' + err);
  });
}

