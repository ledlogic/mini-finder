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

// ── Autocomplete ───────────────────────────────────────────────────────────
let knownNames = [];   // loaded once from /api/names
let activeDropdown = null;

async function loadKnownNames() {
  try {
    const res  = await fetch('/api/names');
    knownNames = await res.json();  // ["Ash Shepherd", "Kunoichi Sisters", ...]
  } catch (e) {
    console.warn('Could not load name suggestions:', e);
  }
}

// Simple fuzzy match — every character in query appears in order in candidate
function fuzzyMatch(query, candidate) {
  query = query.toLowerCase();
  candidate = candidate.toLowerCase();
  // Exact substring first
  if (candidate.includes(query)) return true;
  // Character-order fuzzy
  let qi = 0;
  for (let ci = 0; ci < candidate.length && qi < query.length; ci++) {
    if (candidate[ci] === query[qi]) qi++;
  }
  return qi === query.length;
}

function scoreMatch(query, candidate) {
  query = query.toLowerCase();
  candidate = candidate.toLowerCase();
  if (candidate.startsWith(query)) return 3;
  if (candidate.includes(query))   return 2;
  return 1; // fuzzy
}

function closeAllAutocompletes() {
  document.querySelectorAll('.autocomplete-dropdown').forEach(d => d.remove());
  activeDropdown = null;
}

function attachAutocomplete(input) {
  input.setAttribute('autocomplete', 'off');

  input.addEventListener('input', () => {
    closeAllAutocompletes();
    const query = input.value.trim();
    if (query.length < 1 || knownNames.length === 0) return;

    const matches = knownNames
      .filter(n => fuzzyMatch(query, n))
      .sort((a, b) => scoreMatch(query, b) - scoreMatch(query, a))
      .slice(0, 8);

    if (matches.length === 0) return;

    // Build dropdown
    const dropdown = document.createElement('ul');
    dropdown.className = 'autocomplete-dropdown';

    matches.forEach((name, idx) => {
      const li = document.createElement('li');
      li.className = 'autocomplete-item';
      if (idx === 0) li.classList.add('autocomplete-active');

      // Highlight matching portion
      const ql = query.toLowerCase();
      const nl = name.toLowerCase();
      const start = nl.indexOf(ql);
      if (start >= 0) {
        li.innerHTML =
          name.slice(0, start) +
          '<mark>' + name.slice(start, start + query.length) + '</mark>' +
          name.slice(start + query.length);
      } else {
        li.textContent = name;
      }

      li.addEventListener('mousedown', (e) => {
        e.preventDefault(); // prevent input blur before click registers
        input.value = name;
        input.dispatchEvent(new Event('input'));
        closeAllAutocompletes();
        // Mark save button dirty
        const btn = input.closest('.img-row')?.querySelector('.btn-save');
        if (btn) btn.style.background = 'var(--accent2)';
      });

      dropdown.appendChild(li);
    });

    // Position under the input
    const rect = input.getBoundingClientRect();
    dropdown.style.top    = (rect.bottom + window.scrollY) + 'px';
    dropdown.style.left   = (rect.left   + window.scrollX) + 'px';
    dropdown.style.width  = Math.max(rect.width, 200) + 'px';

    document.body.appendChild(dropdown);
    activeDropdown = dropdown;
  });

  // Keyboard navigation
  input.addEventListener('keydown', (e) => {
    if (!activeDropdown) return;
    const items = activeDropdown.querySelectorAll('.autocomplete-item');
    const activeItem = activeDropdown.querySelector('.autocomplete-active');
    let idx = Array.from(items).indexOf(activeItem);

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      items[idx]?.classList.remove('autocomplete-active');
      items[Math.min(idx + 1, items.length - 1)]?.classList.add('autocomplete-active');
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      items[idx]?.classList.remove('autocomplete-active');
      items[Math.max(idx - 1, 0)]?.classList.add('autocomplete-active');
    } else if (e.key === 'Enter') {
      const active = activeDropdown.querySelector('.autocomplete-active');
      if (active) {
        e.preventDefault();
        input.value = active.textContent.trim();
        input.dispatchEvent(new Event('input'));
        closeAllAutocompletes();
      }
      // If no dropdown active item, fall through to form submit (handled below)
    } else if (e.key === 'Escape') {
      closeAllAutocompletes();
    }
  });

  input.addEventListener('blur', () => {
    // Small delay so mousedown on item fires first
    setTimeout(closeAllAutocompletes, 150);
  });
}

// ── DOMContentLoaded ───────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {

  // Load known names for autocomplete
  await loadKnownNames();

  // Attach autocomplete to all mini_name inputs
  document.querySelectorAll('input[name="mini_name"]').forEach(attachAutocomplete);

  // Dirty-row save button highlight
  document.querySelectorAll('.img-row').forEach(row => {
    const inputs = row.querySelectorAll('input, select');
    const btn    = row.querySelector('.btn-save');
    if (!btn) return;
    const originals = {};
    inputs.forEach(inp => { originals[inp.name] = inp.value; });
    inputs.forEach(inp => {
      inp.addEventListener('input', () => {
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

  // Enter key saves row (only when no autocomplete is active)
  document.querySelectorAll('.img-row input').forEach(inp => {
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !activeDropdown) {
        e.preventDefault();
        inp.closest('form')?.requestSubmit();
      }
    });
  });

  // Close dropdown on scroll (repositioning is complex, just close)
  window.addEventListener('scroll', closeAllAutocompletes, { passive: true });
});
