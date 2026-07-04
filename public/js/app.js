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

// ── Copy sibling fields ──────────────────────────────────────────────────────
async function copySibling(imageId) {
  const btn = document.querySelector(`[data-id="${imageId}"].btn-copy-sibling`);
  const orig = btn.textContent;
  btn.textContent = '…';
  btn.disabled = true;

  let siblings;
  try {
    const res = await fetch(`/images/${imageId}/siblings`);
    if (!res.ok) { btn.textContent = '✕ no name set'; setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2000); return; }
    siblings = await res.json();
  } catch(e) {
    btn.textContent = '✕ error'; setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2000); return;
  }

  btn.textContent = orig;
  btn.disabled = false;

  if (!siblings.length) {
    btn.textContent = '✕ no siblings';
    setTimeout(() => { btn.textContent = orig; }, 2000);
    return;
  }

  // Filter to siblings that have useful data
  const populated = siblings.filter(s => s.species || s.gender || s.stance || s.weapons);
  const source = populated.length === 1 ? populated[0]
    : populated.length > 1  ? await pickSibling(populated)
    : siblings.length === 1 ? siblings[0]
    : await pickSibling(siblings);

  if (!source) return;

  fillFromSibling(imageId, source);
}

function fillFromSibling(imageId, source) {
  const row = document.getElementById(`row-${imageId}`);
  if (!row) return;

  const set = (name, val) => {
    const el = row.querySelector(`[name="${name}"]`);
    if (!el || !val) return;
    el.value = val;
    el.classList.add('cell-copied');
    setTimeout(() => el.classList.remove('cell-copied'), 2000);
  };

  set('species',   source.species);
  set('gender',    source.gender);
  set('stance',    source.stance);
  set('weapons',   source.weapons);
  set('mini_size', source.mini_size);

  // Flash the save button to remind user to save
  const saveBtn = row.querySelector('.btn-save');
  if (saveBtn) {
    saveBtn.style.background = 'var(--warn, #f59e0b)';
    setTimeout(() => saveBtn.style.background = '', 3000);
  }
}

function pickSibling(siblings) {
  return new Promise(resolve => {
    // Build a small inline picker
    const existing = document.getElementById('sibling-picker');
    if (existing) existing.remove();

    const picker = document.createElement('div');
    picker.id = 'sibling-picker';
    picker.className = 'sibling-picker';
    picker.innerHTML = `
      <div class="sibling-picker-inner">
        <div class="sibling-picker-title">Pick sibling to copy from:</div>
        ${siblings.map(s => `
          <button class="sibling-picker-btn" data-id="${s.id}">
            <strong>${s.mini_name}</strong>
            ${[s.stance, s.weapons, s.species, s.gender].filter(Boolean).map(v => `<span>${v}</span>`).join('')}
          </button>`).join('')}
        <button class="sibling-picker-cancel">Cancel</button>
      </div>`;

    picker.querySelectorAll('.sibling-picker-btn').forEach(b => {
      b.addEventListener('click', () => {
        picker.remove();
        resolve(siblings.find(s => s.id == b.dataset.id));
      });
    });
    picker.querySelector('.sibling-picker-cancel').addEventListener('click', () => { picker.remove(); resolve(null); });
    picker.addEventListener('click', e => { if (e.target === picker) { picker.remove(); resolve(null); } });

    document.body.appendChild(picker);
  });
}

// ── Inline collection name edit ──────────────────────────────────────────────
(function() {
  const input  = document.getElementById('col-name-input');
  const save   = document.getElementById('col-name-save');
  if (!input || !save) return;
  const orig = input.value;
  input.addEventListener('input', () => {
    save.style.display = input.value !== orig ? '' : 'none';
  });
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); input.closest('form').submit(); }
    if (e.key === 'Escape') { input.value = orig; save.style.display = 'none'; input.blur(); }
  });
})();

// ── Toggle the cross-reference (secondary image) select ─────────────────────
function toggleXrefSelect(imageId, checked) {
  const select = document.getElementById(`xref-select-${imageId}`);
  if (!select) return;
  select.style.opacity = checked ? '1' : '0.35';
  if (!checked) select.value = '';

  // Live-toggle visibility of name/species/gender fields, printed/painted,
  // and the secondary-of indicator.
  const row = document.getElementById(`row-${imageId}`);
  if (!row) return;
  row.classList.toggle('row-is-secondary', checked);

  // Name/species/gender are now all in one .cell-name-td cell
  const nameCell = row.querySelector('.cell-name-td');
  if (nameCell) {
    nameCell.querySelectorAll('input, select, button:not(.btn-suggestion)').forEach(el => {
      el.style.display = checked ? 'none' : '';
    });
    const suggestion = nameCell.querySelector('.btn-suggestion');
    if (suggestion) suggestion.style.display = checked ? 'none' : '';
  }

  // secondary-of indicator is now in the folder/file cell
  const secondaryOf = row.querySelector('.secondary-of');
  if (secondaryOf) secondaryOf.style.display = checked ? '' : 'none';

  // xref-row border/wrapper
  const xrefRow = row.querySelector('.xref-row');
  if (xrefRow) xrefRow.style.display = checked ? '' : '';  // always visible

  const dash = row.querySelector('.secondary-name-hidden');
  if (dash) dash.style.display = checked ? '' : 'none';

  const printedRow = row.querySelector('select[name="printed"]')?.closest('.count-row');
  const paintedRow = row.querySelector('select[name="painted"]')?.closest('.count-row');
  [printedRow, paintedRow].forEach(r => {
    if (r) r.style.display = checked ? 'none' : '';
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

// ── Lightbox ───────────────────────────────────────────────────────────────
function openLightbox(src) {
  const lb  = document.getElementById('lightbox');
  const img = document.getElementById('lightbox-img');
  if (!lb || !img) return;
  img.src = src;
  lb.classList.add('open');
  document.body.style.overflow = 'hidden';
  event.stopPropagation();
}

function closeLightbox() {
  const lb = document.getElementById('lightbox');
  if (!lb) return;
  lb.classList.remove('open');
  document.body.style.overflow = '';
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    closeLightbox();
    closeAllAutocompletes();
  }
});

// ── Name data ──────────────────────────────────────────────────────────────
let confirmedNames  = [];  // saved mini_name values
let suggestedNames  = [];  // OCR suggested_name values (per image)
let activeDropdown  = null;

// ── Static vocabulary for fixed fields ────────────────────────────────────
const FIELD_VOCAB = {
  species: [
    'HUMAN', 'ROBOT', 'VEHICLE', 'ALIEN', 'CREATURE',
    'UNDEAD', 'BEAST', 'CONSTRUCT', 'HYBRID'
  ],
  stance: [
    'STANDING', 'CROUCHING', 'RUNNING', 'KNEELING', 'CHARGING',
    'PRONE', 'JUMPING', 'RESTING', 'COMBAT', 'MOUNTED'
  ]
};

async function loadNameData() {
  try {
    const [cnRes, snRes] = await Promise.all([
      fetch('/api/names'),
      fetch('/api/suggested_names')
    ]);
    confirmedNames = await cnRes.json();
    suggestedNames = await snRes.json();
  } catch (e) {
    console.warn('Could not load name data:', e);
  }
}

// ── Levenshtein ────────────────────────────────────────────────────────────
function levenshtein(a, b) {
  a = a.toLowerCase(); b = b.toLowerCase();
  const m = a.length, n = b.length;
  const d = Array.from({length: m+1}, (_, i) =>
    Array.from({length: n+1}, (_, j) => i === 0 ? j : j === 0 ? i : 0)
  );
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      d[i][j] = a[i-1] === b[j-1]
        ? d[i-1][j-1]
        : 1 + Math.min(d[i-1][j], d[i][j-1], d[i-1][j-1]);
  return d[m][n];
}

// ── Fuzzy match ────────────────────────────────────────────────────────────
function fuzzyMatch(query, candidate) {
  query = query.toLowerCase();
  candidate = candidate.toLowerCase();
  if (candidate.includes(query)) return true;
  let qi = 0;
  for (let ci = 0; ci < candidate.length && qi < query.length; ci++)
    if (candidate[ci] === query[qi]) qi++;
  return qi === query.length;
}

function scoreMatch(query, candidate) {
  query = query.toLowerCase(); candidate = candidate.toLowerCase();
  if (candidate.startsWith(query)) return 3;
  if (candidate.includes(query))   return 2;
  return 1;
}

// Highlight matched substring in a name
function highlightMatch(query, name) {
  const ql = query.toLowerCase();
  const nl = name.toLowerCase();
  const start = nl.indexOf(ql);
  if (start >= 0) {
    return name.slice(0, start) +
      '<mark>' + name.slice(start, start + query.length) + '</mark>' +
      name.slice(start + query.length);
  }
  return name;
}

// ── Autocomplete ───────────────────────────────────────────────────────────
function closeAllAutocompletes() {
  document.querySelectorAll('.autocomplete-dropdown').forEach(d => d.remove());
  activeDropdown = null;
}

function buildDropdown(input, query) {
  closeAllAutocompletes();
  if (query.length < 1) return;

  const items = [];

  // 1. Near-match warnings from confirmed names (Levenshtein 1-3, not exact)
  confirmedNames.forEach(name => {
    const dist = levenshtein(query, name);
    const exact = name.toLowerCase() === query.toLowerCase();
    if (!exact && dist > 0 && dist <= 3 && query.length > 3) {
      items.push({ type: 'warn', name, dist });
    }
  });

  // 2. Fuzzy matches from confirmed names
  confirmedNames
    .filter(n => fuzzyMatch(query, n))
    .forEach(name => {
      if (!items.find(i => i.name === name)) {
        items.push({ type: 'confirmed', name, score: scoreMatch(query, name) });
      }
    });

  // 3. OCR suggestions (unconfirmed) — fuzzy match
  suggestedNames
    .filter(n => n && fuzzyMatch(query, n))
    .forEach(name => {
      if (!items.find(i => i.name === name)) {
        items.push({ type: 'suggested', name, score: scoreMatch(query, name) });
      }
    });

  if (items.length === 0) return;

  // If the query is very close (dist <= 1) to a confirmed name, suppress everything else
  const veryClose = confirmedNames.find(n => levenshtein(query, n) <= 1);
  if (veryClose) {
    // Only keep the near-exact confirmed match; drop warns and suggested
    items.length = 0;
    items.push({ type: 'confirmed', name: veryClose, score: 3 });
  } else {
    // Sort: warns first, then confirmed (blue) above suggested (grey), then by score desc
    const typeOrder = { warn: 0, confirmed: 1, suggested: 2 };
    items.sort((a, b) => {
      const tDiff = typeOrder[a.type] - typeOrder[b.type];
      if (tDiff !== 0) return tDiff;
      return (b.score || 0) - (a.score || 0);
    });
  }

  const dropdown = document.createElement('ul');
  dropdown.className = 'autocomplete-dropdown';

  items.slice(0, 10).forEach((item, idx) => {
    const li = document.createElement('li');

    if (item.type === 'warn') {
      li.className = 'autocomplete-item autocomplete-warn';
      li.innerHTML = `⚠ Did you mean <strong>${item.name}</strong>? (${item.dist} char difference)`;
    } else if (item.type === 'suggested') {
      li.className = 'autocomplete-item autocomplete-suggested';
      li.innerHTML = `✦ ${highlightMatch(query, item.name)}`;
    } else {
      li.className = 'autocomplete-item autocomplete-confirmed';
      if (idx === 0 || items[0].type === 'warn') li.classList.add('autocomplete-active');
      li.innerHTML = highlightMatch(query, item.name);
    }

    li.addEventListener('mousedown', (e) => {
      e.preventDefault();
      input.value = item.name;
      input.dispatchEvent(new Event('input'));
      closeAllAutocompletes();
      const btn = input.closest('.img-row')?.querySelector('.btn-save');
      if (btn) btn.style.background = 'var(--accent2)';
    });

    dropdown.appendChild(li);
  });

  // Position under input
  const rect = input.getBoundingClientRect();
  dropdown.style.top   = (rect.bottom + window.scrollY) + 'px';
  dropdown.style.left  = (rect.left   + window.scrollX) + 'px';
  dropdown.style.width = Math.max(rect.width, 220) + 'px';

  document.body.appendChild(dropdown);
  activeDropdown = dropdown;
}

// ── Simple autocomplete for fixed-vocabulary fields ────────────────────────
function attachSimpleAutocomplete(input, vocab) {
  input.setAttribute('autocomplete', 'off');

  input.addEventListener('input', () => {
    closeAllAutocompletes();
    const raw   = input.value;
    // Support comma-separated — complete only the last token
    const parts = raw.split(',');
    const query = parts[parts.length - 1].trim();
    if (query.length < 1) return;

    const matches = vocab.filter(v => v.toLowerCase().startsWith(query.toLowerCase()));
    if (matches.length === 0) return;

    const dropdown = document.createElement('ul');
    dropdown.className = 'autocomplete-dropdown';

    matches.forEach((name, idx) => {
      const li = document.createElement('li');
      li.className = 'autocomplete-item autocomplete-confirmed';
      if (idx === 0) li.classList.add('autocomplete-active');
      // Highlight typed portion
      li.innerHTML = '<strong>' + name.slice(0, query.length) + '</strong>' + name.slice(query.length);

      li.addEventListener('mousedown', (e) => {
        e.preventDefault();
        // Replace only the last token
        parts[parts.length - 1] = name;
        input.value = parts.join(', ');
        input.dispatchEvent(new Event('input'));
        closeAllAutocompletes();
        const btn = input.closest('.img-row')?.querySelector('.btn-save');
        if (btn) btn.style.background = 'var(--accent2)';
      });

      dropdown.appendChild(li);
    });

    const rect = input.getBoundingClientRect();
    dropdown.style.top   = (rect.bottom + window.scrollY) + 'px';
    dropdown.style.left  = (rect.left   + window.scrollX) + 'px';
    dropdown.style.width = Math.max(rect.width, 180) + 'px';
    document.body.appendChild(dropdown);
    activeDropdown = dropdown;
  });

  input.addEventListener('keydown', (e) => {
    if (!activeDropdown) return;
    const items  = activeDropdown.querySelectorAll('.autocomplete-item');
    const active = activeDropdown.querySelector('.autocomplete-active');
    let idx = Array.from(items).indexOf(active);

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      items[idx]?.classList.remove('autocomplete-active');
      items[Math.min(idx + 1, items.length - 1)]?.classList.add('autocomplete-active');
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      items[idx]?.classList.remove('autocomplete-active');
      items[Math.max(idx - 1, 0)]?.classList.add('autocomplete-active');
    } else if (e.key === 'Tab' || e.key === 'Enter') {
      const activeItem = activeDropdown.querySelector('.autocomplete-active');
      if (activeItem) {
        e.preventDefault();
        const parts = input.value.split(',');
        parts[parts.length - 1] = activeItem.textContent.trim();
        input.value = parts.join(', ');
        input.dispatchEvent(new Event('input'));
        closeAllAutocompletes();
      }
    } else if (e.key === 'Escape') {
      closeAllAutocompletes();
    }
  });

  input.addEventListener('blur', () => setTimeout(closeAllAutocompletes, 150));
}

// Words in the name field that imply a group/bundle — auto-set mini_count to 4+
const GROUP_KEYWORDS = /\b(bundle|pack|set|group|squad|collection|crew|gang|team|trio|duo|pair|sisters|brothers|twins|friends|party|warband|unit)\b/i;

function syncMiniCount(input) {
  const val = input.value.trim();
  if (!GROUP_KEYWORDS.test(val)) return;

  // Find the mini_count select in the same row (catalog) or on the page (edit)
  const row = input.closest('.img-row');
  if (row) {
    const select = row.querySelector('select[name="mini_count"]');
    if (select && (select.value === '1' || select.value === '')) {
      select.value = '4+';
      select.dispatchEvent(new Event('input'));
      // Flash to draw attention
      select.style.transition = 'background 0.3s';
      select.style.background = 'rgba(255,107,53,0.25)';
      setTimeout(() => select.style.background = '', 1200);
    }
  } else {
    // Edit page — find by name
    const select = document.querySelector('select[name="mini_count"]');
    if (select && (select.value === '1' || select.value === '')) {
      select.value = '4+';
      select.style.transition = 'background 0.3s';
      select.style.background = 'rgba(255,107,53,0.25)';
      setTimeout(() => select.style.background = '', 1200);
    }
  }
}

function attachAutocomplete(input) {
  input.setAttribute('autocomplete', 'off');

  input.addEventListener('input', () => {
    buildDropdown(input, input.value.trim());
    syncMiniCount(input);
  });

  input.addEventListener('keydown', (e) => {
    if (!activeDropdown) return;
    const items = activeDropdown.querySelectorAll('.autocomplete-item');
    const active = activeDropdown.querySelector('.autocomplete-active');
    let idx = Array.from(items).indexOf(active);

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      items[idx]?.classList.remove('autocomplete-active');
      items[Math.min(idx + 1, items.length - 1)]?.classList.add('autocomplete-active');
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      items[idx]?.classList.remove('autocomplete-active');
      items[Math.max(idx - 1, 0)]?.classList.add('autocomplete-active');
    } else if (e.key === 'Enter') {
      const activeItem = activeDropdown.querySelector('.autocomplete-active');
      if (activeItem) {
        e.preventDefault();
        // Extract plain name from the item
        const nameEl = activeItem.querySelector('strong') || activeItem;
        input.value = nameEl.textContent.trim();
        input.dispatchEvent(new Event('input'));
        closeAllAutocompletes();
      }
    } else if (e.key === 'Escape') {
      closeAllAutocompletes();
    }
  });

  input.addEventListener('blur', () => setTimeout(closeAllAutocompletes, 150));
}

// ── DOMContentLoaded ───────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {

  // Scroll to and highlight the row we just saved (from anchor in URL)
  const hash = window.location.hash;
  if (hash && hash.startsWith('#row-')) {
    const target = document.querySelector(hash);
    if (target) {
      // Small delay so the page finishes rendering first
      setTimeout(() => {
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        target.classList.add('row-just-saved');
        setTimeout(() => target.classList.remove('row-just-saved'), 2000);
      }, 80);
    }
  }


  await loadNameData();

  // Attach autocomplete to all mini_name inputs
  document.querySelectorAll('input[name="mini_name"]').forEach(attachAutocomplete);

  // Attach static vocabulary autocomplete to species and stance
  document.querySelectorAll('input[name="species"]').forEach(inp => attachSimpleAutocomplete(inp, FIELD_VOCAB.species));
  document.querySelectorAll('input[name="stance"]').forEach(inp => attachSimpleAutocomplete(inp, FIELD_VOCAB.stance));

  // Dirty-row save button highlight
  document.querySelectorAll('.img-row').forEach(row => {
    const inputs = row.querySelectorAll('input, select');
    const btn    = row.querySelector('.btn-save');
    if (!btn) return;
    const originals = {};
    inputs.forEach(inp => { originals[inp.name] = inp.value; });
    // Store on element so saveRow can reset after a successful save
    row._dirtyOriginals = originals;
    row._dirtyInputs    = inputs;
    inputs.forEach(inp => {
      inp.addEventListener('input', () => {
        const dirty = Array.from(inputs).some(i => i.value !== originals[i.name]);
        btn.style.background = dirty ? 'var(--accent2)' : 'var(--accent)';
      });
      inp.addEventListener('change', () => {
        const dirty = Array.from(inputs).some(i => i.value !== originals[i.name]);
        btn.style.background = dirty ? 'var(--accent2)' : 'var(--accent)';
      });
    });
  });

  // Toast auto-dismiss
  const toast = document.querySelector('.toast');
  if (toast) {
    setTimeout(() => {
      toast.style.transition = 'opacity 0.5s';
      toast.style.opacity = '0';
      setTimeout(() => toast.remove(), 500);
    }, 3500);
  }

  // Enter saves row (only when no dropdown active)
  document.querySelectorAll('.img-row input').forEach(inp => {
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !activeDropdown) {
        e.preventDefault();
        const row = inp.closest('.img-row');
        const btn = row?.querySelector('.btn-save');
        if (btn) btn.click();
      }
    });
  });

  window.addEventListener('scroll', closeAllAutocompletes, { passive: true });
});

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


// ── Field quick-pick buttons (species, stance, etc.) ─────────────────────────
function setFieldQuickpick(btn) {
  var fieldName = btn.dataset.field;
  var value     = btn.dataset.value;
  var row       = btn.closest('tr');
  var input     = row ? row.querySelector('input[name="' + fieldName + '"]') : null;
  if (!input) return;
  input.value = value;
  input.dispatchEvent(new Event('input'));
  btn.closest('.species-quickpick').querySelectorAll('.btn-quickpick').forEach(function(b) {
    b.classList.toggle('btn-quickpick-active', b === btn);
  });
}

// ── Edit page quick-pick buttons ──────────────────────────────────────────────
function editQuickpick(btn) {
  var targetId = btn.dataset.target;
  var value    = btn.dataset.value;
  var input    = document.getElementById(targetId);
  if (!input) return;
  input.value = value;
  input.dispatchEvent(new Event('input'));
  btn.closest('.species-quickpick').querySelectorAll('.btn-quickpick').forEach(function(b) {
    b.classList.remove('btn-quickpick-active');
  });
  btn.classList.add('btn-quickpick-active');
}
