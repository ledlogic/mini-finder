// ── Lightbox ───────────────────────────────────────────────────────────────
function openLightbox(src) {
  const lb = document.getElementById('lightbox');
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
  if (e.key === 'Escape') closeLightbox();
});

// ── Auto-save hint: highlight changed rows ─────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('.img-row').forEach(row => {
    const inputs = row.querySelectorAll('input, select');
    const btn = row.querySelector('.btn-save');
    if (!btn) return;

    // Capture original values
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

  // Keyboard shortcut: Enter saves in catalog table rows
  document.querySelectorAll('.img-row input').forEach(inp => {
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        inp.closest('form')?.requestSubmit();
      }
    });
  });
});
