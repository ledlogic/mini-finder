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

// ── Set cover + optionally mark as bundle ────────────────────────────────────
async function setCoverAndBundle(collectionId, imageId, btn) {
  var row      = btn.closest('tr');
  var nameInp  = row ? row.querySelector('input[name="mini_name"]') : null;
  var mcSel    = row ? row.querySelector('select[name="mini_count"]') : null;
  var saveBtn  = row ? row.querySelector('.btn-save') : null;

  console.log('[setCoverAndBundle] row:', row, 'nameInp:', nameInp, 'mcSel:', mcSel, 'saveBtn:', saveBtn);

  var nameVal  = nameInp ? nameInp.value.trim().toLowerCase() : '';
  var mcVal    = mcSel   ? mcSel.value : '';
  var alreadyBundle = nameVal === 'bundle' || mcVal === '4+' || parseInt(mcVal) >= 4;

  console.log('[setCoverAndBundle] nameVal:', nameVal, 'mcVal:', mcVal, 'alreadyBundle:', alreadyBundle);

  // Always set as cover
  await setCover(collectionId, imageId, btn);

  // If not already a bundle, ask if they want to mark it as one
  if (!alreadyBundle) {
    if (confirm('Also mark this image as the bundle/gallery image?\n(Sets name to "Bundle" and count to 4+)')) {
      console.log('[setCoverAndBundle] marking as bundle');
      if (nameInp) { nameInp.value = 'Bundle'; nameInp.dispatchEvent(new Event('change')); }
      if (mcSel)   { mcSel.value   = '4+';     mcSel.dispatchEvent(new Event('change')); }
      if (saveBtn) {
        console.log('[setCoverAndBundle] clicking save');
        saveBtn.click();
      } else {
        console.warn('[setCoverAndBundle] no save button found!');
      }
    }
  }
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
        // Dismiss missing-bundle alert if this row is now a bundle
        var alertEl = document.getElementById('missing-bundle-alert');
        if (alertEl) {
          var nameInp = row.querySelector('input[name="mini_name"]');
          var mcSel   = row.querySelector('select[name="mini_count"]');
          var nameVal = nameInp ? nameInp.value.trim().toLowerCase() : '';
          var mcVal   = mcSel  ? mcSel.value : '';
          var isBundle = nameVal === 'bundle' || mcVal === '4+' || parseInt(mcVal) >= 4;
          if (isBundle) {
            alertEl.style.transition = 'opacity 0.4s';
            alertEl.style.opacity = '0';
            setTimeout(function() { alertEl.remove(); }, 400);
          }
        }

        // Update incomplete highlight
        var sp = row.querySelector('input[name="species"]');
        var st = row.querySelector('input[name="stance"]');
        var wp = row.querySelector('input[name="weapons"]');
        var mc = row.querySelector('select[name="mini_count"]');
        var isBundle = mc && (mc.value === '4+' || parseInt(mc.value) >= 4);
        var isSecondary = row.querySelector('input[name="is_secondary"]') &&
                          row.querySelector('input[name="is_secondary"]').checked;
        var incomplete = !isBundle && !isSecondary &&
          ((!sp || !sp.value.trim()) || (!st || !st.value.trim()) || (!wp || !wp.value.trim()));
        row.classList.toggle('row-incomplete', !!incomplete);
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
        // Check if row still passes active filters; if not, fade and remove it + its xrefs
        if (rowFailsFilters(row)) {
          // Collect this row and any xref secondaries (rows that link to this image id)
          var toRemove = [row];
          document.querySelectorAll('.img-row').forEach(function(r) {
            var xrefSel = r.querySelector('select[name="primary_image_id"]');
            if (xrefSel && xrefSel.value == id) toRemove.push(r);
          });
          toRemove.forEach(function(r) {
            r.style.transition = 'opacity 0.5s, background 0.5s';
            r.style.opacity = '0.3';
            r.style.background = 'rgba(239,68,68,0.06)';
          });
          setTimeout(function() {
            toRemove.forEach(function(r) { r.remove(); });
            // Remove orphaned collection-header-row if no more rows follow it
            document.querySelectorAll('.collection-header-row').forEach(function(hr) {
              var next = hr.nextElementSibling;
              if (!next || next.classList.contains('collection-header-row')) hr.remove();
            });
            // Update the count display
            var countEl = document.getElementById('catalog-count');
            if (countEl) {
              var remaining = document.querySelectorAll('.img-row').length;
              var strong = countEl.querySelector('strong');
              if (strong) {
                strong.textContent = remaining;
              } else {
                // Plain text format — replace first number
                countEl.textContent = countEl.textContent.replace(/^\d+/, remaining);
              }
            }
          }, 600);
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

