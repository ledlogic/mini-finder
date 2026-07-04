// mf-autocomplete.js
// Name autocomplete, fuzzy matching, and field vocabulary dropdowns

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
