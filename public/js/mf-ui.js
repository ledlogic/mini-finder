// mf-ui.js
// UI init: lightbox, dirty-state watcher, DOMContentLoaded setup

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
  document.querySelectorAll('input[name="species"]').forEach(inp => {
    attachSimpleAutocomplete(inp, FIELD_VOCAB.species);
    // Auto-set gender to NA when typing a non-gendered species
    inp.addEventListener('change', function() {
      applySpeciesRules(inp.value, inp.closest('tr'));
    });
    inp.addEventListener('blur', function() {
      applySpeciesRules(inp.value, inp.closest('tr'));
    });
  });
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
